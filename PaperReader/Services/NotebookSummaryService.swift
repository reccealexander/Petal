import Foundation
import GRDB

/// Posted after a notebook's `ai_summary` is (re)generated, so any open UI
/// showing it (currently `HomeView`'s notebook summary header) can refresh.
public extension Notification.Name {
    static let notebookSummaryDidUpdate = Notification.Name("PaperReader.notebookSummaryDidUpdate")
}

/// Generates and caches an AI summary of a notebook's papers/highlights/
/// comments/notes via the user's selected AI provider.
///
/// The entry point, `noteCreated(forPaperId:)`, is called only after a new
/// paper-scoped note has been inserted. A persisted count guard provides a
/// second line of defense: generation proceeds only when the note count has
/// grown since the last successful summary.
public final class NotebookSummaryService: @unchecked Sendable {
    /// Shared across service instances so rapid note creation cannot start
    /// overlapping free-tier requests. Pending checks are coalesced per paper;
    /// each check re-reads the persisted count after the prior one finishes.
    private static let regenerationGate = SummaryRegenerationGate()

    private let database: DatabaseManager
    private let keychain: KeychainService
    private let gemini: GeminiClient
    private let claude: ClaudeClient
    private let notebookRepository: NotebookRepository
    private let noteRepository: NoteRepository
    private let highlightRepository: HighlightRepository

    public init(database: DatabaseManager) {
        self.database = database
        self.keychain = KeychainService()
        self.gemini = GeminiClient(keychain: keychain)
        self.claude = ClaudeClient(keychain: keychain)
        self.notebookRepository = NotebookRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.highlightRepository = HighlightRepository(database: database)
    }

    /// Fire-and-forget entry point called after a paper-scoped note is created.
    /// Regeneration checks are serialized and coalesced to prevent overlapping
    /// requests when several notes are created in quick succession.
    public func noteCreated(forPaperId paperId: String) {
        Task { [self] in
            await Self.regenerationGate.enqueue(paperId: paperId) { [self] in
                await regenerateIfNeeded(forPaperId: paperId)
            }
        }
    }

    // MARK: - Guarded regenerate

    private func regenerateIfNeeded(forPaperId paperId: String) async {
        guard let notebookId = notebookId(forPaperId: paperId) else {
            // Paper isn't filed in any notebook — nothing to summarize.
            return
        }

        guard let notebook = try? notebookRepository.notebook(id: notebookId) else {
            return
        }

        let currentCount = currentNoteCount(forNotebookId: notebookId)
        guard Self.shouldRegenerate(
            currentNoteCount: currentCount,
            summarizedNoteCount: notebook.aiSummaryNoteCount
        ) else {
            // No net-new note since the last summary — don't regenerate.
            return
        }

        guard let provider = AIProviderPreference.effectiveProvider(keychain: keychain) else {
            // No key configured — leave ai_summary as-is; the UI shows the
            // "not generated yet" placeholder in this case.
            return
        }

        let digest = buildDigest(forNotebook: notebook)

        let system = """
        You are summarizing a research notebook. Produce a concise, well-structured \
        summary (main themes, methods, key findings, and open questions) grounded in \
        the papers, highlights, comments, and notes provided. Do not invent content.
        """

        var full = ""
        do {
            switch provider {
            case .claude:
                let stream = claude.streamMessage(
                    system: system,
                    messages: [ClaudeMessage(role: "user", content: digest)]
                )
                for try await delta in stream { full += delta }
            case .gemini:
                let stream = gemini.streamMessage(
                    system: system,
                    messages: [GeminiMessage(role: "user", content: digest)]
                )
                for try await delta in stream { full += delta }
            }
        } catch {
            // Network/API failure — leave the cached summary untouched.
            return
        }

        let summary = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        try? await database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notebook SET ai_summary = ?, ai_summary_note_count = ? WHERE id = ?",
                arguments: [summary, currentCount, notebookId]
            )
        }

        NotificationCenter.default.post(name: .notebookSummaryDidUpdate, object: nil)
    }

    /// Pure decision seam for the persisted count guard. Keeping this
    /// independent of provider/keychain state makes the no-network behavior
    /// directly regression-testable.
    static func shouldRegenerate(currentNoteCount: Int, summarizedNoteCount: Int) -> Bool {
        currentNoteCount > summarizedNoteCount
    }

    // MARK: - Lookups

    /// The notebook a paper is currently filed under, or nil if unfiled.
    private func notebookId(forPaperId paperId: String) -> String? {
        try? database.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT notebook_id FROM paper WHERE id = ?", arguments: [paperId])
        } ?? nil
    }

    /// Total note count "belonging" to a notebook: notes directly linked to
    /// the notebook, plus notes linked to any paper in the notebook's subtree
    /// (recursive — includes sub-notebooks), matching
    /// `NotebookRepository.papersUnder(notebookId:)`'s scope.
    private func currentNoteCount(forNotebookId notebookId: String) -> Int {
        (try? database.dbQueue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: """
                WITH RECURSIVE sub_notebooks(id) AS (
                    SELECT id FROM notebook WHERE id = ?
                    UNION ALL
                    SELECT n.id FROM notebook n JOIN sub_notebooks s ON n.parent_id = s.id
                )
                SELECT COUNT(*) FROM note
                WHERE notebook_id IN (SELECT id FROM sub_notebooks)
                   OR paper_id IN (SELECT id FROM paper WHERE notebook_id IN (SELECT id FROM sub_notebooks))
                """,
                arguments: [notebookId]
            ) ?? 0
        }) ?? 0
    }

    // MARK: - Digest assembly (what's sent to Gemini)

    /// Assembles a focused text digest for the summary request: for every
    /// paper in the notebook's subtree, its title/authors, its highlights'
    /// selected text and any comment bodies, and its paper-linked notes; plus
    /// any notes attached directly to the notebook itself. Deliberately does
    /// NOT include raw extracted PDF text (unlike
    /// `ContextBuilder.buildNotebookSystemPrompt`, which is built for
    /// interactive Q&A and can inline full paper text for small notebooks) —
    /// a summary only needs the user's own annotations plus paper metadata,
    /// so this keeps the request small and cheap regardless of notebook size.
    private func buildDigest(forNotebook notebook: Notebook) -> String {
        let papers = (try? notebookRepository.papersUnder(notebookId: notebook.id)) ?? []
        let allNotes = (try? noteRepository.allNotes()) ?? []

        var sections: [String] = []
        sections.append("Notebook: \(notebook.name)")

        if papers.isEmpty {
            sections.append("(no papers in this notebook yet)")
        } else {
            for paper in papers {
                sections.append(paperSection(paper: paper, allNotes: allNotes))
            }
        }

        let notebookNotes = allNotes.filter { $0.notebookId == notebook.id }
        if !notebookNotes.isEmpty {
            let notesText = notebookNotes.map { note -> String in
                if let title = note.title, !title.isEmpty {
                    return "- \(title): \(note.body)"
                }
                return "- \(note.body)"
            }.joined(separator: "\n")
            sections.append("Notes attached directly to this notebook:\n\(notesText)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func paperSection(paper: Paper, allNotes: [Note]) -> String {
        let title = paper.title ?? "Untitled"
        let authors = paper.authors ?? "Unknown"

        var lines: [String] = ["Paper: \(title)", "Authors: \(authors)"]

        if let highlights = try? highlightRepository.highlights(forPaper: paper.id), !highlights.isEmpty {
            var highlightLines: [String] = []
            for highlight in highlights {
                let text = highlight.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    highlightLines.append("- \"\(text)\"")
                }
                if let comment = try? highlightRepository.comment(forHighlight: highlight.id) {
                    let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        highlightLines.append("  comment: \(body)")
                    }
                }
            }
            if !highlightLines.isEmpty {
                lines.append("Highlights/comments:\n" + highlightLines.joined(separator: "\n"))
            }
        }

        let paperNotes = allNotes.filter { $0.paperId == paper.id }
        if !paperNotes.isEmpty {
            let notesText = paperNotes.map { note -> String in
                if let title = note.title, !title.isEmpty {
                    return "- \(title): \(note.body)"
                }
                return "- \(note.body)"
            }.joined(separator: "\n")
            lines.append("Notes:\n\(notesText)")
        }

        return lines.joined(separator: "\n")
    }
}

/// Serializes notebook-summary checks without blocking their callers. Actor
/// reentrancy allows new paper ids to be queued while a generation is waiting
/// on its provider stream; the draining task then processes the latest queue.
private actor SummaryRegenerationGate {
    typealias Operation = @Sendable () async -> Void

    private var pending: [String: Operation] = [:]
    private var isDraining = false

    func enqueue(paperId: String, operation: @escaping Operation) async {
        pending[paperId] = operation
        guard !isDraining else { return }

        isDraining = true
        while let (nextPaperId, nextOperation) = pending.first {
            pending.removeValue(forKey: nextPaperId)
            await nextOperation()
        }
        isDraining = false
    }
}
