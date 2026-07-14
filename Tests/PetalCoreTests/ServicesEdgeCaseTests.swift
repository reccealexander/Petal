import XCTest
@testable import PetalCore

/// Adversarial edge-case coverage for the AI-services parsers and prompt
/// builders: `KeyIdeaSuggestionService.parseKeyIdeas`,
/// `TagSuggestionService.parseTags`, `AIProviderPreference` selection logic,
/// and every `QuickActionPrompts` template.
///
/// Every assertion here characterizes the *actual* current behavior so the
/// suite stays green. Where that behavior is surprising or wrong, the comment
/// says so (and the accompanying investigation report tracks it as a bug);
/// these are deliberately not written as failing tests.
final class ServicesEdgeCaseTests: XCTestCase {

    // MARK: - parseKeyIdeas: adversarial input

    func testUnicodeAndRTLSentencePassesThroughVerbatim() {
        let arabic = "هذا اكتشاف مهم جدا في هذه الورقة."
        let cjk = "本研究提出了一种新方法。"
        let emoji = "The result improved 📈 by 30%."
        let text = "\(arabic)\n\(cjk)\n\(emoji)"

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            [arabic, cjk, emoji]
        )
    }

    func testSmartQuoteWrappedRTLSentenceIsUnwrapped() {
        let inner = "هذا اكتشاف مهم."
        // Curly double quotes around an RTL sentence should be stripped just
        // like around Latin text.
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: "“\(inner)”"),
            [inner]
        )
    }

    func testExtremelyLongLineIsPreservedIntact() {
        let long = String(repeating: "a", count: 20_000) + "."
        let parsed = KeyIdeaSuggestionService.parseKeyIdeas(from: long)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.count, 20_001)
    }

    func testMixedNumberedBulletedAndQuotedMarkersAllStripped() {
        let text = """
        1. \"First idea.\"
        - Second idea.
        • 'Third idea.'
        3) “Fourth idea.”
        """

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["First idea.", "Second idea.", "Third idea.", "Fourth idea."]
        )
    }

    func testPreambleLineEndingInColonIsDropped() {
        let text = """
        Key findings are summarized below:
        The catalyst doubled the reaction rate.
        """
        // The colon-terminated header (no . ! ?) is treated as preamble and skipped.
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["The catalyst doubled the reaction rate."]
        )
    }

    func testColonLineContainingSentencePunctuationIsKept() {
        // "Fig. 1 shows this:" ends in ':' but also contains '.', so the
        // preamble heuristic does NOT drop it. Documents the exact boundary of
        // the isPreamble rule (hasSuffix(":") AND no . ! ?).
        let line = "Fig. 1 shows this:"
        XCTAssertEqual(KeyIdeaSuggestionService.parseKeyIdeas(from: line), [line])
    }

    func testBlankAndWhitespaceOnlyLinesAreIgnored() {
        let text = "First.\n   \n\t\nSecond.\n \n"
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["First.", "Second."]
        )
    }

    func testEmptyAndWhitespaceOnlyInputYieldsNothing() {
        XCTAssertEqual(KeyIdeaSuggestionService.parseKeyIdeas(from: ""), [])
        XCTAssertEqual(KeyIdeaSuggestionService.parseKeyIdeas(from: "   \n\t\n  "), [])
    }

    func testCarriageReturnNewlinesAreSplitCorrectly() {
        // CRLF line endings must not fold two sentences into one, nor emit a
        // blank entry between them.
        let text = "First.\r\nSecond.\r\nThird."
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["First.", "Second.", "Third."]
        )
    }

    func testDuplicateSentencesAreDeduplicated() {
        let text = "Same sentence.\nSame sentence.\nOther."
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["Same sentence.", "Other."]
        )
    }

    func testOnlyQuoteCharactersProducesNoOutput() {
        // A line that is just a pair of quotes collapses to empty and is dropped.
        XCTAssertEqual(KeyIdeaSuggestionService.parseKeyIdeas(from: "\"\"\n''"), [])
    }

    // MARK: - parseKeyIdeas: the 5-vs-25 cap and limit parameter

    func testDefaultLimitCapsAtFive() {
        let text = (1...10).map { "Sentence \($0)." }.joined(separator: "\n")
        let parsed = KeyIdeaSuggestionService.parseKeyIdeas(from: text)
        XCTAssertEqual(parsed.count, 5)
        XCTAssertEqual(parsed, ["Sentence 1.", "Sentence 2.", "Sentence 3.", "Sentence 4.", "Sentence 5."])
    }

    func testEveryParagraphLimitCapsAtTwentyFive() {
        let text = (1...40).map { "Sentence \($0)." }.joined(separator: "\n")
        let parsed = KeyIdeaSuggestionService.parseKeyIdeas(from: text, limit: 25)
        XCTAssertEqual(parsed.count, 25)
        XCTAssertEqual(parsed.last, "Sentence 25.")
    }

    func testCustomLimitIsHonored() {
        let text = (1...10).map { "Sentence \($0)." }.joined(separator: "\n")
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text, limit: 3),
            ["Sentence 1.", "Sentence 2.", "Sentence 3."]
        )
    }

    func testZeroLimitReturnsEverythingRatherThanNothing() {
        // Characterization of a fragile guard: the loop breaks on
        // `result.count == limit`, so limit == 0 never triggers the break and
        // ALL lines are returned. Production only ever passes 5 or 25, but a
        // 0 limit silently means "no cap" instead of "no results". Tracked as
        // a robustness bug in the report.
        let text = "One.\nTwo.\nThree."
        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text, limit: 0),
            ["One.", "Two.", "Three."]
        )
    }

    // MARK: - TagSuggestionService.parseTags

    func testTagsAreSplitTrimmedLowercasedAndDeduplicated() {
        let text = "Machine Learning, deep learning ,  Machine Learning , NLP"
        XCTAssertEqual(
            TagSuggestionService.parseTags(from: text),
            ["machine learning", "deep learning", "nlp"]
        )
    }

    func testTagsSplitOnNewlinesAndCommas() {
        let text = "ai, ml\nnlp\ntransformers, ai"
        XCTAssertEqual(
            TagSuggestionService.parseTags(from: text),
            ["ai", "ml", "nlp", "transformers"]
        )
    }

    func testTagsBulletAndQuoteWrappersAreStripped() {
        let text = "- ai\n* ml\n• nlp\n\"vision\"\n'graphs'\n`rl`"
        XCTAssertEqual(
            TagSuggestionService.parseTags(from: text),
            ["ai", "ml", "nlp", "vision", "graphs", "rl"]
        )
    }

    func testTagsAreCappedAtEight() {
        let text = (1...20).map { "tag\($0)" }.joined(separator: ", ")
        let parsed = TagSuggestionService.parseTags(from: text)
        XCTAssertEqual(parsed.count, 8)
        XCTAssertEqual(parsed.last, "tag8")
    }

    func testTagsFromPurePunctuationOrWhitespaceAreDropped() {
        let text = "  , --- , *, \n, ai"
        XCTAssertEqual(TagSuggestionService.parseTags(from: text), ["ai"])
    }

    func testNumberedListPrefixLeaksIntoTags() {
        // BUG characterization: unlike parseKeyIdeas, parseTags does NOT strip
        // a leading "1." / "2." enumerator (digits aren't in its trim set), so
        // a numbered reply pollutes every tag with its ordinal. Bulleted
        // replies (previous test) are cleaned; numbered ones are not.
        let text = "1. ai\n2. ml"
        XCTAssertEqual(TagSuggestionService.parseTags(from: text), ["1. ai", "2. ml"])
    }

    func testEmptyTagInputYieldsEmptyList() {
        XCTAssertEqual(TagSuggestionService.parseTags(from: ""), [])
        XCTAssertEqual(TagSuggestionService.parseTags(from: "   \n , , \n"), [])
    }

    // MARK: - AIProviderPreference (offline preference/selection logic)

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "AIProviderPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testPreferredDefaultsToGeminiWhenUnset() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AIProviderPreference.preferred(defaults: defaults), .gemini)
    }

    func testPreferredFallsBackToGeminiForUnknownRawValue() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai", forKey: AIProviderPreference.userDefaultsKey)
        XCTAssertEqual(AIProviderPreference.preferred(defaults: defaults), .gemini)
    }

    func testPreferredRoundTripsBothProviders() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        AIProviderPreference.setPreferred(.claude, defaults: defaults)
        XCTAssertEqual(AIProviderPreference.preferred(defaults: defaults), .claude)
        XCTAssertEqual(
            defaults.string(forKey: AIProviderPreference.userDefaultsKey),
            "claude"
        )

        AIProviderPreference.setPreferred(.gemini, defaults: defaults)
        XCTAssertEqual(AIProviderPreference.preferred(defaults: defaults), .gemini)
        XCTAssertEqual(
            defaults.string(forKey: AIProviderPreference.userDefaultsKey),
            "gemini"
        )
    }

    func testProviderRawValuesAndAllCasesOrdering() {
        // effectiveProvider's "sole available provider" fallback iterates
        // AIProvider.allCases in order; pin that order and the raw values that
        // KeychainService keys off of.
        XCTAssertEqual(AIProvider.allCases, [.claude, .gemini])
        XCTAssertEqual(AIProvider.claude.rawValue, "claude")
        XCTAssertEqual(AIProvider.gemini.rawValue, "gemini")
    }

    // MARK: - QuickActionPrompts.userMessage — paper-scope actions

    func testExplainEquationRequiresSelection() {
        XCTAssertNil(QuickActionPrompts.userMessage(for: .explainEquation, context: QuickActionContext()))
        XCTAssertNil(QuickActionPrompts.userMessage(
            for: .explainEquation,
            context: QuickActionContext(selection: "   \n ")
        ))
    }

    func testExplainEquationEmbedsSelectionAndSurrounding() {
        let message = QuickActionPrompts.userMessage(
            for: .explainEquation,
            context: QuickActionContext(selection: "E = mc^2", surrounding: "from relativity")
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("E = mc^2"))
        XCTAssertTrue(message!.contains("from relativity"))
    }

    func testExplainEquationTrimsSelectionWhitespace() {
        let message = QuickActionPrompts.userMessage(
            for: .explainEquation,
            context: QuickActionContext(selection: "  E = mc^2  ")
        )
        // nonEmpty trims, so the embedded quote wraps the trimmed value.
        XCTAssertEqual(message?.contains("\"E = mc^2\""), true)
    }

    func testSummarizeSectionPrefersSelectionThenPageText() {
        let fromSelection = QuickActionPrompts.userMessage(
            for: .summarizeSection,
            context: QuickActionContext(selection: "SELECTED", pageText: "PAGE")
        )
        XCTAssertEqual(fromSelection?.contains("SELECTED"), true)
        XCTAssertEqual(fromSelection?.contains("PAGE"), false)

        let fromPage = QuickActionPrompts.userMessage(
            for: .summarizeSection,
            context: QuickActionContext(pageText: "PAGE")
        )
        XCTAssertEqual(fromPage?.contains("PAGE"), true)

        XCTAssertNil(QuickActionPrompts.userMessage(for: .summarizeSection, context: QuickActionContext()))
    }

    func testExplainHighlightWithAndWithoutComment() {
        let noComment = QuickActionPrompts.userMessage(
            for: .explainHighlight,
            context: QuickActionContext(highlightText: "important claim")
        )
        XCTAssertEqual(noComment?.contains("important claim"), true)
        XCTAssertEqual(noComment?.contains("My comment:"), false)

        let withComment = QuickActionPrompts.userMessage(
            for: .explainHighlight,
            context: QuickActionContext(highlightText: "important claim", commentText: "why?")
        )
        XCTAssertEqual(withComment?.contains("My comment: why?"), true)

        XCTAssertNil(QuickActionPrompts.userMessage(for: .explainHighlight, context: QuickActionContext()))
    }

    func testExplainHighlightIgnoresWhitespaceOnlyComment() {
        let message = QuickActionPrompts.userMessage(
            for: .explainHighlight,
            context: QuickActionContext(highlightText: "claim", commentText: "   ")
        )
        XCTAssertEqual(message?.contains("My comment:"), false)
    }

    // MARK: - QuickActionPrompts.userMessage — notebook-scope actions

    func testRelateToNotebookPrecedenceSelectionHighlightTitle() {
        let sel = QuickActionPrompts.userMessage(
            for: .relateToNotebook,
            context: QuickActionContext(selection: "SEL", highlightText: "HL", paperTitle: "TITLE")
        )
        XCTAssertEqual(sel?.contains("SEL"), true)

        let hl = QuickActionPrompts.userMessage(
            for: .relateToNotebook,
            context: QuickActionContext(highlightText: "HL", paperTitle: "TITLE")
        )
        XCTAssertEqual(hl?.contains("HL"), true)
        XCTAssertEqual(hl?.contains("TITLE"), false)

        let title = QuickActionPrompts.userMessage(
            for: .relateToNotebook,
            context: QuickActionContext(paperTitle: "TITLE")
        )
        XCTAssertEqual(title?.contains("the paper \"TITLE\""), true)

        XCTAssertNil(QuickActionPrompts.userMessage(for: .relateToNotebook, context: QuickActionContext()))
    }

    func testFindConnectionsAndSummarizeNotebookAlwaysAvailable() {
        // These two ignore context entirely — even a fully empty context must
        // yield a non-nil message (they operate on the notebook system prompt).
        for action in [QuickAction.findConnections, .summarizeNotebook] {
            XCTAssertNotNil(
                QuickActionPrompts.userMessage(for: action, context: QuickActionContext()),
                "\(action) should always produce a message"
            )
        }
    }

    func testEveryActionHandlesEmptyContextWithoutCrashing() {
        // Smoke test across all cases: nil for the four context-dependent
        // actions, non-nil for the two notebook-wide ones.
        for action in QuickAction.allCases {
            let message = QuickActionPrompts.userMessage(for: action, context: QuickActionContext())
            switch action {
            case .findConnections, .summarizeNotebook:
                XCTAssertNotNil(message, "\(action) must be available with empty context")
            default:
                XCTAssertNil(message, "\(action) must be unavailable with empty context")
            }
        }
    }

    // MARK: - QuickActionPrompts.unavailableReason

    func testUnavailableReasonMirrorsUserMessageAvailability() {
        // Whenever userMessage is nil (unavailable) the reason must be
        // non-nil, and vice versa — for the four context-dependent actions.
        let emptyContext = QuickActionContext()
        for action in [QuickAction.explainEquation, .summarizeSection, .explainHighlight, .relateToNotebook] {
            XCTAssertNil(QuickActionPrompts.userMessage(for: action, context: emptyContext))
            XCTAssertNotNil(QuickActionPrompts.unavailableReason(for: action, context: emptyContext))
        }

        let fullContext = QuickActionContext(
            selection: "s", pageText: "p", highlightText: "h", paperTitle: "t"
        )
        for action in [QuickAction.explainEquation, .summarizeSection, .explainHighlight, .relateToNotebook] {
            XCTAssertNil(QuickActionPrompts.unavailableReason(for: action, context: fullContext))
        }
    }

    func testUnavailableReasonAlwaysNilForNotebookWideActions() {
        for action in [QuickAction.findConnections, .summarizeNotebook] {
            XCTAssertNil(QuickActionPrompts.unavailableReason(for: action, context: QuickActionContext()))
        }
    }

    // MARK: - QuickActionPrompts.keyIdeaUserMessage

    func testKeyIdeaUserMessageIncludesPageTextAndOmitsFocusWhenNoInstruction() {
        let message = QuickActionPrompts.keyIdeaUserMessage(pageText: "PAGE BODY")
        XCTAssertTrue(message.contains("PAGE BODY"))
        XCTAssertFalse(message.contains("specifically interested in"))
        XCTAssertTrue(message.contains("1-5 sentences"))
    }

    func testKeyIdeaUserMessageAddsFocusLineWhenInstructionGiven() {
        let message = QuickActionPrompts.keyIdeaUserMessage(pageText: "P", instruction: "  the methodology  ")
        // Instruction is trimmed before embedding.
        XCTAssertTrue(message.contains("specifically interested in: the methodology."))
        XCTAssertFalse(message.contains("  the methodology  "))
    }

    func testKeyIdeaUserMessageEveryParagraphChangesTask() {
        let perParagraph = QuickActionPrompts.keyIdeaUserMessage(pageText: "P", everyParagraph: true)
        XCTAssertTrue(perParagraph.contains("paragraph by paragraph"))
        XCTAssertFalse(perParagraph.contains("1-5 sentences"))
    }

    func testKeyIdeaUserMessageWhitespaceInstructionTreatedAsEmpty() {
        let message = QuickActionPrompts.keyIdeaUserMessage(pageText: "P", instruction: "   \n\t")
        XCTAssertFalse(message.contains("specifically interested in"))
    }
}
