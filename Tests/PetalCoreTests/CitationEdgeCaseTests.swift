import XCTest
@testable import PetalCore

/// Adversarial edge-case coverage for the citation feature. Every assertion
/// documents the CURRENT behavior of `CitationFormatter` /
/// `CitationMetadataService`. Where the current behavior is arguably wrong the
/// test comment is prefixed with `BUG:` so the intent is not mistaken for an
/// endorsement — the assertion still matches what the code does today so the
/// suite stays green and acts as a change-detector.
final class CitationEdgeCaseTests: XCTestCase {

    // MARK: - Author parsing: unicode / accents

    func testParsesAccentedNaturalName() {
        let authors = CitationAuthor.parse(from: "José García")
        XCTAssertEqual(authors, [CitationAuthor(given: "José", family: "García")])
    }

    func testParsesAccentedInvertedNameStaysSingleAuthor() {
        // Accented letters satisfy `isLetter`, so the inverted-name heuristic
        // keeps this as ONE author.
        let authors = CitationAuthor.parse(from: "García, José")
        XCTAssertEqual(authors, [CitationAuthor(given: "José", family: "García")])
    }

    // MARK: - Author parsing: hyphenated names

    func testParsesHyphenatedSurnameNaturalOrder() {
        let authors = CitationAuthor.parse(from: "Jean-Paul Sartre")
        XCTAssertEqual(authors, [CitationAuthor(given: "Jean-Paul", family: "Sartre")])
    }

    func testHyphenatedGivenNameInInvertedFormIsMisSplit() {
        // BUG: `looksLikeGivenNames` rejects the hyphen (not `.isLetter`), so a
        // single inverted name with a hyphenated first name is treated as a
        // comma-separated LIST and split into two bogus authors.
        let authors = CitationAuthor.parse(from: "Smith, Jean-Paul")
        XCTAssertEqual(authors.count, 2)
        XCTAssertEqual(authors[0], CitationAuthor(given: nil, family: "Smith"))
        XCTAssertEqual(authors[1], CitationAuthor(given: nil, family: "Jean-Paul"))
    }

    // MARK: - Author parsing: suffixes

    func testSuffixJrBecomesFamilyName() {
        // BUG: "First Last Jr." takes the final token as the family, so the
        // suffix "Jr." is mistaken for the surname.
        let authors = CitationAuthor.parse(from: "John Smith Jr.")
        XCTAssertEqual(authors, [CitationAuthor(given: "John Smith", family: "Jr.")])
    }

    func testSuffixRomanNumeralBecomesFamilyName() {
        // BUG: same failure mode for generational suffixes.
        let authors = CitationAuthor.parse(from: "John Smith III")
        XCTAssertEqual(authors, [CitationAuthor(given: "John Smith", family: "III")])
    }

    // MARK: - Author parsing: mononyms / caps / initials

    func testMononymSingleWord() {
        let authors = CitationAuthor.parse(from: "Plato")
        XCTAssertEqual(authors, [CitationAuthor(given: nil, family: "Plato")])
    }

    func testAllCapsName() {
        let authors = CitationAuthor.parse(from: "JANE DOE")
        XCTAssertEqual(authors, [CitationAuthor(given: "JANE", family: "DOE")])
    }

    func testInitialsWithPeriodsNaturalOrder() {
        let authors = CitationAuthor.parse(from: "J. M. Smith")
        XCTAssertEqual(authors, [CitationAuthor(given: "J. M.", family: "Smith")])
        XCTAssertEqual(authors.first?.initials, "J. M.")
    }

    func testInitialsWithoutPeriodsCollapseToFirstLetter() {
        // "JM" is treated as a single given token so only its first letter
        // becomes an initial.
        let a = CitationAuthor(given: "JM", family: "Smith")
        XCTAssertEqual(a.initials, "J.")
    }

    // MARK: - Author parsing: separators / empties

    func testSemicolonInvertedListWithInitials() {
        let authors = CitationAuthor.parse(from: "Smith, J.; Doe, J.")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "J.", family: "Smith"),
            CitationAuthor(given: "J.", family: "Doe")
        ])
    }

    func testEmptyTokensAndTrailingSeparatorsAreDropped() {
        let authors = CitationAuthor.parse(from: "John Smith; ; Jane Doe;")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    func testTrailingCommaOnFullNameDoesNotProduceEmptyAuthor() {
        let authors = CitationAuthor.parse(from: "John Smith,")
        XCTAssertEqual(authors, [CitationAuthor(given: "John", family: "Smith")])
    }

    func testAuthorStringAlreadyContainingEtAl() {
        // BUG: "et al." is not recognized; it is folded into the name tokens so
        // "al." becomes the family name.
        let authors = CitationAuthor.parse(from: "John Smith et al.")
        XCTAssertEqual(authors, [CitationAuthor(given: "John Smith et", family: "al.")])
    }

    func testAndSeparatorWithThreeAuthors() {
        let authors = CitationAuthor.parse(from: "John Smith and Jane Doe and Al Roe")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe"),
            CitationAuthor(given: "Al", family: "Roe")
        ])
    }

    // MARK: - APA: sparse / missing fields

    func testAPAAuthorOnlyNoStrayPunctuation() {
        let m = CitationMetadata(authors: [CitationAuthor(given: "John", family: "Smith")])
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertEqual(out, "Smith, J.")
    }

    func testAPAMissingYearKeepsJournalWithoutEmptyParens() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "T",
            container: "J",
            volume: "12",
            issue: "3",
            pages: "45-67"
        )
        let out = CitationFormatter.format(m, style: .apa)
        // Only the issue parens appear; no empty "()" year block.
        XCTAssertEqual(out, "Smith, J. T. *J*, *12*(3), 45-67.")
    }

    func testAPAEmptyMetadataProducesEmptyString() {
        let out = CitationFormatter.format(CitationMetadata(), style: .apa)
        XCTAssertEqual(out, "")
    }

    func testAPADoiWinsOverArxivWhenBothPresent() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "T",
            doi: "10.1/abc",
            arxivId: "1901.01234"
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertTrue(out.hasSuffix("https://doi.org/10.1/abc"), out)
        XCTAssertFalse(out.contains("arxiv.org"), out)
    }

    // MARK: - MLA: URL terminal-period inconsistency

    func testMLAUrlHasNoTerminalPeriodWhenNoTail() {
        // BUG (minor): with no container/volume/year, the canonical URL is
        // appended WITHOUT a trailing period.
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Title",
            doi: "10.1/x"
        )
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertEqual(out, "Smith, John. \u{201C}Title.\u{201D} https://doi.org/10.1/x")
    }

    func testMLAUrlHasTerminalPeriodWhenTailPresent() {
        // Contrast: when a tail (year) is present the same URL DOES get a period.
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Title",
            year: 2020,
            doi: "10.1/x"
        )
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertEqual(out, "Smith, John. \u{201C}Title.\u{201D} 2020. https://doi.org/10.1/x.")
    }

    func testMLATitleOnlyTrimsTrailingSpace() {
        let m = CitationMetadata(authors: [], title: "Solo")
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertEqual(out, "\u{201C}Solo.\u{201D}")
    }

    // MARK: - Chicago: sparse

    func testChicagoYearWithoutContainer() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Title",
            year: 2020
        )
        let out = CitationFormatter.format(m, style: .chicago)
        XCTAssertEqual(out, "Smith, John. \u{201C}Title.\u{201D} 2020.")
    }

    func testChicagoNoContainerNoYear() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Title"
        )
        let out = CitationFormatter.format(m, style: .chicago)
        XCTAssertEqual(out, "Smith, John. \u{201C}Title.\u{201D}")
    }

    func testChicagoElevenAuthorsUseEtAl() {
        let authors = (1...11).map { CitationAuthor(given: "A", family: "F\($0)") }
        let m = CitationMetadata(authors: authors, title: "T")
        let out = CitationFormatter.format(m, style: .chicago)
        XCTAssertTrue(out.hasPrefix("F1, A, et al."), out)
    }

    // MARK: - BibTeX: special-character escaping

    func testBibTeXPercentInTitleIsEscaped() {
        // "%" starts a comment in a .bib file, so it must be escaped as "\%".
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "50% Faster Training",
            year: 2020,
            container: "J"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.contains(#"title = {50\% Faster Training}"#), out)
    }

    func testBibTeXAmpersandInTitleIsEscaped() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "Cats & Dogs"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.contains(#"title = {Cats \& Dogs}"#), out)
    }

    func testBibTeXBracesInTitleAreEscaped() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "A {Study}"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.contains(#"title = {A \{Study\}}"#), out)
    }

    func testBibTeXUnicodeInTitleIsPassedThroughRaw() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "Über Netze"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.contains("title = {Über Netze}"), out)
    }

    // MARK: - BibTeX: cite-key generation

    func testBibTeXCiteKeyIncludesStopWord() {
        // BUG: the docstring promises "first significant title word" but the
        // implementation keeps articles like "The".
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "The Deep Net",
            year: 2020
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@misc{smith2020the,"), out)
    }

    func testBibTeXCiteKeyKeepsNonASCIIUnicode() {
        // BUG: cite keys should be ASCII for portability; accented letters are
        // kept (many BibTeX tools reject non-ASCII keys).
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Müller")],
            title: "Über Netze",
            year: 2021
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@misc{müller2021über,"), out)
    }

    func testBibTeXCiteKeyFallsBackToCitation() {
        let out = CitationFormatter.format(CitationMetadata(), style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@misc{citation,"), out)
    }

    func testBibTeXEmptyStringContainerYieldsArticleWithoutJournal() {
        // BUG: a non-nil but empty container flips the entry type to @article
        // while the journal field is suppressed, producing an invalid @article.
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "T",
            container: ""
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@article{"), out)
        XCTAssertFalse(out.contains("journal ="), out)
    }

    func testBibTeXAuthorFieldUsesFamilyCommaGiven() {
        let m = CitationMetadata(authors: [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: nil, family: "WHO")
        ])
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.contains("author = {Smith, John and WHO}"), out)
    }

    // MARK: - RIS

    func testRISNewlineInTitleIsFlattened() {
        // RIS is a line-oriented tag format, so an embedded newline is flattened
        // to a space rather than producing a tagless continuation line.
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "Line1\nLine2"
        )
        let out = CitationFormatter.format(m, style: .ris)
        XCTAssertTrue(out.contains("TI  - Line1 Line2"), out)
        XCTAssertFalse(out.contains("TI  - Line1\nLine2"), out)
    }

    func testRISEmptyStringContainerStillClaimsJOUR() {
        // BUG: mirror of the BibTeX empty-container issue — TY becomes JOUR with
        // no JO line.
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "T",
            container: ""
        )
        let out = CitationFormatter.format(m, style: .ris)
        XCTAssertTrue(out.contains("TY  - JOUR"), out)
        XCTAssertFalse(out.contains("JO  -"), out)
    }

    func testRISUsesArxivURLWhenNoDoi() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "T",
            arxivId: "1901.01234"
        )
        let out = CitationFormatter.format(m, style: .ris)
        XCTAssertTrue(out.contains("UR  - https://arxiv.org/abs/1901.01234"), out)
    }

    // MARK: - CitationMetadata assembly

    func testMetadataFromPaperWithHyphenatedInvertedAuthorMisSplits() {
        // End-to-end reflection of the parser bug through `init(paper:)`.
        let paper = Paper(title: "T", authors: "Smith, Jean-Paul", filePath: "x.pdf")
        let m = CitationMetadata(paper: paper)
        XCTAssertEqual(m.authors.count, 2)
    }

    func testCanonicalURLPrefersDoi() {
        let m = CitationMetadata(doi: "10.1/x", arxivId: "1901.01234")
        XCTAssertEqual(m.canonicalURL, "https://doi.org/10.1/x")
    }

    func testCanonicalURLNilWhenNoIdentifiers() {
        XCTAssertNil(CitationMetadata().canonicalURL)
    }

    // MARK: - CrossRef merge: malformed / partial payloads

    func testCrossRefMergeUsesOrganizationNameAuthor() {
        let fallback = CitationMetadata(authors: [], title: "T")
        let message: [String: Any] = [
            "author": [["name": "World Health Organization"]]
        ]
        let merged = CitationMetadataService.mergeCrossRef(message, into: fallback)
        XCTAssertEqual(merged.authors, [CitationAuthor(given: nil, family: "World Health Organization")])
    }

    func testCrossRefMergeIgnoresEmptyTitleArray() {
        let fallback = CitationMetadata(authors: [], title: "Kept")
        let merged = CitationMetadataService.mergeCrossRef(["title": [String]()], into: fallback)
        XCTAssertEqual(merged.title, "Kept")
    }

    func testCrossRefMergeIgnoresEmptyStringTitle() {
        let fallback = CitationMetadata(authors: [], title: "Kept")
        let merged = CitationMetadataService.mergeCrossRef(["title": [""]], into: fallback)
        XCTAssertEqual(merged.title, "Kept")
    }

    func testCrossRefMergeIgnoresWronglyTypedAuthorField() {
        let fallback = CitationMetadata(authors: [CitationAuthor(given: "Old", family: "Author")])
        let merged = CitationMetadataService.mergeCrossRef(["author": "not-an-array"], into: fallback)
        XCTAssertEqual(merged.authors, fallback.authors)
    }

    func testCrossRefMergeAuthorMissingFamilyIsDropped() {
        let fallback = CitationMetadata(authors: [CitationAuthor(given: "Old", family: "Author")])
        // Neither `family` nor `name` present -> item yields nil -> parsed empty
        // -> fallback authors preserved.
        let merged = CitationMetadataService.mergeCrossRef(["author": [["given": "Only"]]], into: fallback)
        XCTAssertEqual(merged.authors, fallback.authors)
    }

    func testCrossRefYearSkipsEmptyDatePartsAndFindsLaterField() {
        let fallback = CitationMetadata(authors: [])
        let message: [String: Any] = [
            "published-print": ["date-parts": [[Int]]()],   // empty outer -> skip
            "issued": ["date-parts": [[2019]]]
        ]
        let merged = CitationMetadataService.mergeCrossRef(message, into: fallback)
        XCTAssertEqual(merged.year, 2019)
    }

    func testCrossRefYearEmptyInnerDatePartsYieldsNoYear() {
        let fallback = CitationMetadata(authors: [])
        let message: [String: Any] = ["issued": ["date-parts": [[Int]()]]]
        let merged = CitationMetadataService.mergeCrossRef(message, into: fallback)
        XCTAssertNil(merged.year)
    }

    // MARK: - arXiv merge

    func testArxivMergeJournalRefOverridesDefaultContainer() {
        let fallback = CitationMetadata(authors: [])
        let entry = ArxivEntry(title: "T", authors: ["A B"], year: 2020, journalRef: "NeurIPS 2020")
        let merged = CitationMetadataService.mergeArxiv(entry, arxivId: "1", into: fallback)
        XCTAssertEqual(merged.container, "NeurIPS 2020")
    }

    func testArxivMergeDefaultsContainerToArxiv() {
        let fallback = CitationMetadata(authors: [])
        let entry = ArxivEntry(title: "T", authors: ["A B"], year: 2020)
        let merged = CitationMetadataService.mergeArxiv(entry, arxivId: "1", into: fallback)
        XCTAssertEqual(merged.container, "arXiv")
    }

    // MARK: - arXiv Atom parsing: malformed / empty / partial

    func testArxivParserReturnsNilOnMalformedXML() {
        XCTAssertNil(ArxivAtomParser().parse(Data("<feed><entry".utf8)))
    }

    func testArxivParserReturnsNilOnEmptyData() {
        XCTAssertNil(ArxivAtomParser().parse(Data()))
    }

    func testArxivParserReturnsNilWhenNoEntry() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>ArXiv Query</title>
        </feed>
        """
        XCTAssertNil(ArxivAtomParser().parse(Data(xml.utf8)))
    }

    func testArxivParserStopsAfterFirstEntry() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>First</title><author><name>A B</name></author></entry>
          <entry><title>Second</title><author><name>C D</name></author></entry>
        </feed>
        """
        let entry = ArxivAtomParser().parse(Data(xml.utf8))
        XCTAssertEqual(entry?.title, "First")
        XCTAssertEqual(entry?.authors, ["A B"])
    }

    func testArxivParserExtractsDoiAndJournalRef() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
          <entry>
            <title>T</title>
            <published>2018-01-02T00:00:00Z</published>
            <author><name>A B</name></author>
            <arxiv:doi>10.1/xyz</arxiv:doi>
            <arxiv:journal_ref>Journal X</arxiv:journal_ref>
          </entry>
        </feed>
        """
        let entry = ArxivAtomParser().parse(Data(xml.utf8))
        XCTAssertEqual(entry?.doi, "10.1/xyz")
        XCTAssertEqual(entry?.journalRef, "Journal X")
        XCTAssertEqual(entry?.year, 2018)
    }

    func testArxivParserCollapsesWhitespaceOnlyAfterMerge() {
        // The parser itself trims but does not collapse internal whitespace;
        // that collapsing happens in mergeArxiv.
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>Deep
            Nets</title><author><name>A B</name></author></entry>
        </feed>
        """
        let entry = ArxivAtomParser().parse(Data(xml.utf8))
        let merged = CitationMetadataService.mergeArxiv(entry!, arxivId: "1", into: CitationMetadata(authors: []))
        XCTAssertEqual(merged.title, "Deep Nets")
    }

    // MARK: - Service: offline fallback never throws

    func testCanEnrichFalseForWhitespaceIdentifiers() {
        let paper = Paper(doi: "   ", arxivId: "  ", filePath: "x.pdf")
        XCTAssertFalse(CitationMetadataService.canEnrich(paper))
    }

    func testCanEnrichTrueWhenDoiPresent() {
        let paper = Paper(doi: "10.1/x", filePath: "x.pdf")
        XCTAssertTrue(CitationMetadataService.canEnrich(paper))
    }

    func testEnrichedMetadataReturnsFallbackWhenNoIdentifiers() async {
        let fallback = CitationMetadata(
            authors: [CitationAuthor(given: "J", family: "Smith")],
            title: "Offline Title"
        )
        let service = CitationMetadataService()
        let result = await service.enrichedMetadata(from: fallback)
        XCTAssertEqual(result, fallback)
    }
}
