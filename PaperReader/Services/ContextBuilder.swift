import Foundation
import PDFKit
import GRDB

/// Builds the system prompt sent to Claude for paper-scope Q&A.
///
/// Context (the full PDF text plus the user's highlights/comments) is
/// rebuilt fresh every time `buildPaperSystemPrompt` is called — there is no
/// caching here. Callers that want to avoid re-extracting PDF text on every
/// message should cache the result themselves.
///
/// Paper scope only. Notebook-scope context building is a future session's
/// work and intentionally does not live here.
public final class ContextBuilder {
    private let highlightRepository: HighlightRepository

    public init(database: DatabaseManager) {
        self.highlightRepository = HighlightRepository(database: database)
    }

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

    /// Concatenates every page's extracted text, separated by blank lines.
    /// Returns an empty string if the document can't be opened.
    private static func extractText(from pdfURL: URL) -> String {
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
