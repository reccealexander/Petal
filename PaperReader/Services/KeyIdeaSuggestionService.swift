import Foundation

/// Selects verbatim key-idea sentences from the text of one paper page.
public final class KeyIdeaSuggestionService: @unchecked Sendable {
    private let keychain: KeychainService
    private let claude: GeminiClient

    private static let maxPageCharacters = 6000

    public init() {
        self.keychain = KeychainService()
        self.claude = GeminiClient(keychain: keychain)
    }

    public var hasAPIKey: Bool {
        keychain.hasAPIKey
    }

    /// Upper bound on suggestions per page. When `everyParagraph` is on we allow
    /// more, since a dense page can hold many paragraphs, each contributing one.
    private static let maxKeyIdeas = 5
    private static let maxParagraphIdeas = 25

    public func suggestKeyIdeas(
        pageText: String,
        instruction: String = "",
        everyParagraph: Bool = false
    ) async throws -> [String] {
        guard hasAPIKey else {
            throw GeminiClientError.missingAPIKey
        }

        let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let boundedPageText = String(trimmed.prefix(Self.maxPageCharacters))
        let system = QuickActionPrompts.keyIdeaSystemPrompt
        let user = QuickActionPrompts.keyIdeaUserMessage(
            pageText: boundedPageText,
            instruction: instruction,
            everyParagraph: everyParagraph
        )

        var full = ""
        let stream = claude.streamMessage(
            system: system,
            messages: [GeminiMessage(role: "user", content: user)]
        )
        for try await delta in stream {
            full += delta
        }

        let limit = everyParagraph ? Self.maxParagraphIdeas : Self.maxKeyIdeas
        return Self.parseKeyIdeas(from: full, limit: limit)
    }

    /// Parses only line-delimited output so punctuation within a sentence is
    /// retained exactly as emitted by Gemini.
    static func parseKeyIdeas(from text: String, limit: Int = maxKeyIdeas) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var sentence = rawLine.trimmingCharacters(in: .whitespaces)
            sentence = sentence.replacingOccurrences(
                of: #"^(?:[-•*]\s*|\d+[.)]\s*)"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            if sentence.count >= 2,
               let first = sentence.first,
               let last = sentence.last,
               (first == "\"" && last == "\"" ||
                first == "'" && last == "'" ||
                first == "“" && last == "”" ||
                first == "‘" && last == "’") {
                sentence = String(sentence.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
            }

            guard !sentence.isEmpty else { continue }
            let isPreamble = sentence.hasSuffix(":") &&
                sentence.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil
            guard !isPreamble, seen.insert(sentence).inserted else { continue }

            result.append(sentence)
            if result.count == limit { break }
        }

        return result
    }
}
