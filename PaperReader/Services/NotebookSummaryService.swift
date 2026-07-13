import CryptoKit
import Foundation
import GRDB

/// Posted after a notebook's `ai_summary` is (re)generated, so any open UI
/// showing it can refresh.
public extension Notification.Name {
    static let notebookSummaryDidUpdate = Notification.Name("PaperReader.notebookSummaryDidUpdate")
}

/// Generates and caches an AI summary from bounded excerpts of the PDFs in a
/// notebook. Regeneration is guarded by a stable signature of the paper-ID set.
public final class NotebookSummaryService: @unchecked Sendable {
    /// Shared across service instances so free-tier requests remain serialized.
    /// Pending checks are coalesced by notebook ID.
    private static let regenerationGate = SummaryRegenerationGate()
    private static let excerptCharacterLimit = 2_000

    private let database: DatabaseManager
    private let keychain: KeychainService
    private let gemini: GeminiClient
    private let claude: ClaudeClient
    private let notebookRepository: NotebookRepository

    public init(database: DatabaseManager) {
        self.database = database
        self.keychain = KeychainService()
        self.gemini = GeminiClient(keychain: keychain)
        self.claude = ClaudeClient(keychain: keychain)
        self.notebookRepository = NotebookRepository(database: database)
    }

    /// Fire-and-forget entry point for a notebook whose recursive paper set may
    /// have changed. Checks are serialized and coalesced per notebook.
    public func notebookPaperSetChanged(notebookId: String) {
        Task { [self] in
            await Self.regenerationGate.enqueue(notebookId: notebookId) { [self] in
                await regenerateIfNeeded(notebookId: notebookId)
            }
        }
    }

    private func regenerateIfNeeded(notebookId: String) async {
        guard let notebook = try? notebookRepository.notebook(id: notebookId) else {
            return
        }

        let papers = (try? notebookRepository.papersUnder(notebookId: notebookId)) ?? []
        let paperIDs = papers.map(\.id)
        guard Self.shouldRegenerate(
            currentPaperIDs: paperIDs,
            summarizedPaperIDsHash: notebook.aiSummaryPaperIdsHash
        ) else {
            return
        }

        guard let provider = AIProviderPreference.effectiveProvider(keychain: keychain) else {
            return
        }

        let signature = Self.paperSetSignature(for: paperIDs)
        let digest = buildDigest(forNotebook: notebook, papers: papers)
        let system = """
        You are summarizing a research notebook. Produce a concise, well-structured \
        summary of its main themes, methods, key findings, connections, and open \
        questions. Ground the summary only in the supplied PDF excerpts. Do not \
        invent content or rely on user notes.
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
            return
        }

        let summary = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }

        let didPersist = (try? await database.dbQueue.write { db -> Bool in
            let currentPaperIDs = try Self.paperIDs(in: notebookId, db: db)
            guard Self.paperSetSignature(for: currentPaperIDs) == signature else {
                return false
            }
            try db.execute(
                sql: """
                UPDATE notebook
                SET ai_summary = ?, ai_summary_paper_ids_hash = ?, ai_summary_paper_count = ?
                WHERE id = ?
                """,
                arguments: [summary, signature, paperIDs.count, notebookId]
            )
            return db.changesCount > 0
        }) ?? false

        if didPersist {
            NotificationCenter.default.post(name: .notebookSummaryDidUpdate, object: nil)
        } else {
            // Membership changed while the provider was streaming. Queue one
            // fresh check; the gate will coalesce it with any existing check.
            notebookPaperSetChanged(notebookId: notebookId)
        }
    }

    static func shouldRegenerate(
        currentPaperIDs: [String],
        summarizedPaperIDsHash: String?
    ) -> Bool {
        paperSetSignature(for: currentPaperIDs) != summarizedPaperIDsHash
    }

    /// UUID strings cannot contain NUL, so this delimiter makes the sorted-ID
    /// serialization unambiguous before hashing.
    static func paperSetSignature(for paperIDs: [String]) -> String {
        let serialized = paperIDs.sorted().joined(separator: "\0")
        let digest = SHA256.hash(data: Data(serialized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func paperIDs(in notebookId: String, db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            WITH RECURSIVE sub_notebooks(id) AS (
                SELECT id FROM notebook WHERE id = ?
                UNION ALL
                SELECT n.id FROM notebook n JOIN sub_notebooks s ON n.parent_id = s.id
            )
            SELECT id FROM paper
            WHERE notebook_id IN (SELECT id FROM sub_notebooks)
            ORDER BY id
            """,
            arguments: [notebookId]
        )
    }

    // MARK: - PDF digest

    /// Sends title/authors plus at most the first 2,000 extracted characters
    /// from each current paper. No notes, highlights, or comments are included.
    private func buildDigest(forNotebook notebook: Notebook, papers: [Paper]) -> String {
        var sections = ["Notebook: \(notebook.name)"]
        guard !papers.isEmpty else {
            sections.append("(no papers in this notebook yet)")
            return sections.joined(separator: "\n\n")
        }

        for paper in papers {
            let url = PDFImportService.fileURL(for: paper, in: database.papersDirectory)
            let extracted = ContextBuilder.extractText(from: url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = extracted.isEmpty
                ? "(PDF text could not be extracted)"
                : String(extracted.prefix(Self.excerptCharacterLimit))
            sections.append("""
            Paper: \(paper.title ?? "Untitled")
            Authors: \(paper.authors ?? "Unknown")
            PDF excerpt (first \(Self.excerptCharacterLimit) characters maximum):
            \(excerpt)
            """)
        }

        return sections.joined(separator: "\n\n")
    }
}

private actor SummaryRegenerationGate {
    typealias Operation = @Sendable () async -> Void

    private var pending: [String: Operation] = [:]
    private var isDraining = false

    func enqueue(notebookId: String, operation: @escaping Operation) async {
        pending[notebookId] = operation
        guard !isDraining else { return }

        isDraining = true
        while let (nextNotebookId, nextOperation) = pending.first {
            pending.removeValue(forKey: nextNotebookId)
            await nextOperation()
        }
        isDraining = false
    }
}
