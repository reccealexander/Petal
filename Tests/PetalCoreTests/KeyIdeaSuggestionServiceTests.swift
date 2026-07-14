import XCTest
@testable import PetalCore

final class KeyIdeaSuggestionServiceTests: XCTestCase {
    func testPlainSentencesPassThroughVerbatim() {
        let text = "The method is fast, accurate, and robust.\nResults improved by 12.5%."

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["The method is fast, accurate, and robust.", "Results improved by 12.5%."]
        )
    }

    func testNumberedAndBulletedPrefixesAreStripped() {
        let text = """
        1. First sentence.
        2) Second sentence.
        - Third sentence.
        • Fourth sentence.
        * Fifth sentence.
        """

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["First sentence.", "Second sentence.", "Third sentence.", "Fourth sentence.", "Fifth sentence."]
        )
    }

    func testWrappingStraightAndSmartQuotesAreStripped() {
        let text = "\"Straight quote.\"\n“Smart double quote.”\n‘Smart single quote.’"

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["Straight quote.", "Smart double quote.", "Smart single quote."]
        )
    }

    func testBlankLinesDuplicatesAndResultsBeyondFiveAreDropped() {
        let text = "One.\n\nOne.\nTwo.\nThree.\nFour.\nFive.\nSix."

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text),
            ["One.", "Two.", "Three.", "Four.", "Five."]
        )
    }

    func testHigherLimitAllowsMoreThanFiveForEveryParagraphMode() {
        let text = "One.\nTwo.\nThree.\nFour.\nFive.\nSix.\nSeven."

        XCTAssertEqual(
            KeyIdeaSuggestionService.parseKeyIdeas(from: text, limit: 25),
            ["One.", "Two.", "Three.", "Four.", "Five.", "Six.", "Seven."]
        )
    }

    func testCasingAndInternalPunctuationArePreserved() {
        let sentence = "DNA-binding increased; however, pH-dependent activity did NOT."

        XCTAssertEqual(KeyIdeaSuggestionService.parseKeyIdeas(from: sentence), [sentence])
    }
}
