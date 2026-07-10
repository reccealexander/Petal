import Foundation
import PDFKit

/// Generates AI-recommended tags for a paper via Claude (Session 7 Part A,
/// Feature 1). Assembles whatever context is already available in the app —
/// title/authors, the first couple of PDF pages, existing highlight
/// selections + their comments, and the paper's primary note — so the user
/// is never asked to paste anything themselves.
///
/// This is a plain, SwiftUI-free class so it stays unit-testable; the reader
/// UI (`ReaderTagPopoverModel`) is responsible for driving it and for
/// filtering out tags the paper already has.
public final class TagSuggestionService: @unchecked Sendable {
    private let keychain: KeychainService
    private let claude: ClaudeClient
    private let highlightRepository: HighlightRepository
    private let noteRepository: NoteRepository
    private let papersDirectory: URL

    /// Cap on how much PDF/text context is sent to Claude, to keep the
    /// request small and cheap.
    private static let maxContextCharacters = 4000

    public init(database: DatabaseManager) {
        self.keychain = KeychainService()
        self.claude = ClaudeClient(keychain: keychain)
        self.highlightRepository = HighlightRepository(database: database)
        self.noteRepository = NoteRepository(database: database)
        self.papersDirectory = database.papersDirectory
    }

    /// Whether an Anthropic API key is currently configured. The reader UI
    /// checks this before offering to generate suggestions.
    public var hasAPIKey: Bool {
        keychain.hasAPIKey
    }

    /// Asks Claude for 5-8 short topical tags for `paper`, derived entirely
    /// from context already stored in the app. Throws
    /// `ClaudeClientError.missingAPIKey` (without making a network call) if
    /// no key is configured.
    ///
    /// Internally this is a thin wrapper around `buildContext(for:)` (a
    /// synchronous, pure function) followed by `suggestTags(context:)` (the
    /// async network call, which only ever touches `Sendable` `String`
    /// values). Callers on a different actor than `Paper` was created on —
    /// e.g. a `@MainActor` reader view-model in another module — should
    /// prefer calling those two directly, the same way `ClaudePanelViewModel`
    /// builds its system prompt synchronously before ever `await`ing:
    /// `Paper` isn't declared `Sendable`, so handing it directly into an
    /// `async` call from another isolation domain trips Swift 6's strict
    /// concurrency checker even though every stored property it has is
    /// Sendable.
    public func suggestTags(for paper: Paper) async throws -> [String] {
        guard hasAPIKey else {
            throw ClaudeClientError.missingAPIKey
        }
        let context = buildContext(for: paper)
        return try await suggestTags(context: context)
    }

    /// Asks Claude for 5-8 short topical tags given an already-assembled
    /// context string (see `buildContext(for:)`). Only ever crosses
    /// isolation domains with plain `String`/`Sendable` values.
    public func suggestTags(context: String) async throws -> [String] {
        guard hasAPIKey else {
            throw ClaudeClientError.missingAPIKey
        }

        let system = "You suggest concise topical tags for scientific papers."
        let user = """
            Given this paper context, suggest 5-8 short lowercase tags as a comma-separated list and nothing else.

            \(context)
            """

        var full = ""
        let stream = claude.streamMessage(system: system, messages: [ClaudeMessage(role: "user", content: user)])
        for try await delta in stream {
            full += delta
        }

        return Self.parseTags(from: full)
    }

    // MARK: - Context assembly

    /// Synchronously assembles title/authors/PDF-excerpt/highlights/notes
    /// context for `paper`. Pure and side-effect-free (aside from best-effort
    /// DB/file reads), so it's safe to call directly from any actor.
    public func buildContext(for paper: Paper) -> String {
        var parts: [String] = []

        if let title = paper.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Title: \(title)")
        }
        if let authors = paper.authors, !authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Authors: \(authors)")
        }

        if let excerpt = firstPagesText(for: paper), !excerpt.isEmpty {
            parts.append("Excerpt:\n\(excerpt)")
        }

        if let highlightContext = highlightContext(for: paper), !highlightContext.isEmpty {
            parts.append("Highlights and comments:\n\(highlightContext)")
        }

        if let note = try? noteRepository.primaryNote(forPaper: paper.id),
           !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Notes:\n\(note.body)")
        }

        let joined = parts.joined(separator: "\n\n")
        return String(joined.prefix(Self.maxContextCharacters))
    }

    private func firstPagesText(for paper: Paper) -> String? {
        let url = PDFImportService.fileURL(for: paper, in: papersDirectory)
        guard let document = PDFDocument(url: url) else { return nil }

        var text = ""
        if let page0 = document.page(at: 0)?.string {
            text += page0
        }
        if document.pageCount > 1, let page1 = document.page(at: 1)?.string {
            text += "\n" + page1
        }
        return String(text.prefix(Self.maxContextCharacters))
    }

    private func highlightContext(for paper: Paper) -> String? {
        guard let highlights = try? highlightRepository.highlights(forPaper: paper.id), !highlights.isEmpty else {
            return nil
        }

        var lines: [String] = []
        for highlight in highlights.prefix(25) {
            let text = highlight.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("- \(text)")
            }
            if let comment = try? highlightRepository.comment(forHighlight: highlight.id) {
                let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    lines.append("  comment: \(body)")
                }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Splits Claude's comma/newline-separated reply into trimmed, lowercased,
    /// deduplicated tag strings, capped to 8.
    static func parseTags(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let trimChars = CharacterSet(charactersIn: "-•*.\"'` ").union(.whitespacesAndNewlines)

        var seen = Set<String>()
        var result: [String] = []
        for piece in text.components(separatedBy: separators) {
            let trimmed = piece.trimmingCharacters(in: trimChars).lowercased()
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count >= 8 { break }
        }
        return result
    }
}
