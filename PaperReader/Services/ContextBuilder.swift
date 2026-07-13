import Foundation
import PDFKit
import GRDB

/// Builds the system prompt sent to Claude for both paper-scope and
/// notebook-scope Q&A (Session 7 Part B).
///
/// Context (PDF text plus the user's highlights/comments/notes) is rebuilt
/// fresh every time `buildPaperSystemPrompt`/`buildNotebookSystemPrompt` is
/// called — there is no caching here. Callers that want to avoid
/// re-extracting PDF text on every message should cache the result
/// themselves.
public final class ContextBuilder {
    private let highlightRepository: HighlightRepository
    private let notebookRepository: NotebookRepository
    private let noteRepository: NoteRepository
    private let papersDirectory: URL

    public init(database: DatabaseManager) {
        self.highlightRepository = HighlightRepository(database: database)
        self.notebookRepository = NotebookRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.papersDirectory = database.papersDirectory
    }

    // MARK: - Paper scope

    /// Builds the full system prompt for a paper-scope Claude conversation.
    public func buildPaperSystemPrompt(paper: Paper, pdfURL: URL) -> String {
        let pdfText = Self.extractText(from: pdfURL)
        let highlightsSection = highlightsAndCommentsFormatted(forPaper: paper.id)

        let title = paper.title ?? "Untitled"
        let authors = paper.authors ?? "Unknown"

        return """
        You are helping the user understand a scientific paper they're reading.

        Paper title: \(title)
        Authors: \(authors)

        Full text:
        \(pdfText)

        The user has made these highlights and comments while reading:
        \(highlightsSection)

        Answer the user's questions about this paper. Reference specific sections,
        equations, or their own annotations where relevant.
        """
    }

    // MARK: - Notebook scope

    /// Token budgeting for notebook-scope prompts. Raw PDF text is expensive
    /// (a handful of papers can easily blow past a usable context window), so
    /// we only inline full text when the notebook is small; otherwise we fall
    /// back to a per-paper digest (title/authors/highlights/comments/notes,
    /// no raw text) which is always included regardless of size.
    ///
    /// These are deliberately simple, explicit, and easy to retune:
    /// - `fullTextPaperLimit`: max number of papers before we give up on full
    ///   text altogether, no matter how short they are.
    /// - `combinedCharBudget`: max combined character count (across all
    ///   papers' extracted text) we're willing to inline. ~200k chars is
    ///   roughly 50k tokens at the common approximation of ~4 chars/token —
    ///   a conservative slice of a larger context window, leaving headroom
    ///   for the digest, notes, conversation history, and the reply itself.
    private static let fullTextPaperLimit = 3
    private static let combinedCharBudget = 200_000

    /// Builds the full system prompt for a notebook-scope Claude conversation
    /// (spec §4). Always includes the notebook name, each paper's
    /// title/authors/highlights/comments, each paper's notes, and notes
    /// attached directly to the notebook. Full raw paper text is included
    /// only when the notebook is small enough per the budget above.
    public func buildNotebookSystemPrompt(notebook: Notebook) -> String {
        // Recursive lookup — includes papers in nested sub-notebooks.
        let papers = (try? notebookRepository.papersUnder(notebookId: notebook.id)) ?? []
        let allNotes = (try? noteRepository.allNotes()) ?? []

        let papersSection = papers.isEmpty
            ? "(no papers in this notebook yet)"
            : papers.map { paperDigest(paper: $0, allNotes: allNotes) }.joined(separator: "\n\n")

        // Notes attached directly to the notebook (as opposed to notes
        // attached to one of its papers, which are folded into each paper's
        // digest above).
        let notebookNotes = allNotes.filter { $0.notebookId == notebook.id }
        let notebookNotesSection = notesFormatted(notebookNotes)

        let fullTextSection = fullTextSection(for: papers)

        return """
        You are helping the user think across a collection of papers in their
        notebook "\(notebook.name)".

        Papers in this notebook:
        \(papersSection)

        Notes attached directly to this notebook (not tied to a specific paper):
        \(notebookNotesSection)

        \(fullTextSection)

        Answer questions that may span multiple papers — connections, contradictions,
        open questions the user has raised in their notes.
        """
    }

    /// One paper's always-included digest: title, authors, its highlights and
    /// their comments, and any notes attached to that paper. This is the part
    /// of the notebook prompt that's included regardless of the token budget.
    private func paperDigest(paper: Paper, allNotes: [Note]) -> String {
        let title = paper.title ?? "Untitled"
        let authors = paper.authors ?? "Unknown"
        let highlightsSection = highlightsAndCommentsFormatted(forPaper: paper.id)
        let paperNotes = allNotes.filter { $0.paperId == paper.id }
        let notesSection = notesFormatted(paperNotes)

        return """
        Paper: \(title)
        Authors: \(authors)
        Highlights/comments:
        \(highlightsSection)
        Notes:
        \(notesSection)
        """
    }

    /// Full raw text section, honoring the budget documented on
    /// `fullTextPaperLimit`/`combinedCharBudget`. Returns an explanatory
    /// placeholder (rather than an empty string) when omitted, so the model
    /// knows raw text isn't available and to rely on the digests above.
    private func fullTextSection(for papers: [Paper]) -> String {
        guard !papers.isEmpty else { return "" }

        guard papers.count <= Self.fullTextPaperLimit else {
            return """
            Full text of each paper: omitted — this notebook has \(papers.count) papers, \
            more than the \(Self.fullTextPaperLimit)-paper limit for inlining full text. \
            Rely on the per-paper digests above (title/authors/highlights/comments/notes).
            """
        }

        let extracted: [(paper: Paper, text: String)] = papers.map { paper in
            let url = PDFImportService.fileURL(for: paper, in: papersDirectory)
            return (paper, Self.extractText(from: url))
        }
        let combinedLength = extracted.reduce(0) { $0 + $1.text.count }

        guard combinedLength <= Self.combinedCharBudget else {
            return """
            Full text of each paper: omitted — the combined extracted text (\(combinedLength) \
            characters) exceeds the \(Self.combinedCharBudget)-character budget. \
            Rely on the per-paper digests above (title/authors/highlights/comments/notes).
            """
        }

        let sections = extracted.map { "### \($0.paper.title ?? "Untitled")\n\($0.text)" }
        return "Full text of each paper:\n" + sections.joined(separator: "\n\n")
    }

    /// Formats a list of notes as a bullet list (title if present, then
    /// body). Returns `"(none)"` if there are none.
    private func notesFormatted(_ notes: [Note]) -> String {
        guard !notes.isEmpty else { return "(none)" }
        return notes.map { note -> String in
            if let title = note.title, !title.isEmpty {
                return "- \(title): \(note.body)"
            }
            return "- \(note.body)"
        }.joined(separator: "\n")
    }

    // MARK: - Shared helpers

    /// Concatenates every page's extracted text, separated by blank lines.
    /// Returns an empty string if the document can't be opened.
    static func extractText(from pdfURL: URL) -> String {
        guard let document = PDFDocument(url: pdfURL) else {
            return ""
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    /// Formats the paper's highlights (and any attached comment) as a bullet
    /// list. Returns `"(none yet)"` if there are none.
    private func highlightsAndCommentsFormatted(forPaper paperId: String) -> String {
        guard let highlights = try? highlightRepository.highlights(forPaper: paperId), !highlights.isEmpty else {
            return "(none yet)"
        }

        var lines: [String] = []
        for highlight in highlights {
            lines.append("- [page \(highlight.page + 1)] \"\(highlight.selectedText)\"")
            if let comment = try? highlightRepository.comment(forHighlight: highlight.id) {
                lines.append("  Comment: \(comment.body)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
