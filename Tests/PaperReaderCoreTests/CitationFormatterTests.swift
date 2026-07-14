import XCTest
@testable import PaperReaderCore

final class CitationFormatterTests: XCTestCase {

    // MARK: - Author parsing

    func testParsesCommaSeparatedFullNames() {
        let authors = CitationAuthor.parse(from: "John Smith, Jane Doe")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    func testParsesSingleInvertedName() {
        let authors = CitationAuthor.parse(from: "Smith, John")
        XCTAssertEqual(authors, [CitationAuthor(given: "John", family: "Smith")])
    }

    func testParsesSingleInvertedNameWithInitials() {
        let authors = CitationAuthor.parse(from: "Smith, J. M.")
        XCTAssertEqual(authors, [CitationAuthor(given: "J. M.", family: "Smith")])
    }

    func testParsesSemicolonSeparatedInvertedNames() {
        let authors = CitationAuthor.parse(from: "Smith, John; Doe, Jane")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    func testParsesAndSeparatedNames() {
        let authors = CitationAuthor.parse(from: "John Smith and Jane Doe")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    func testParsesAmpersandSeparatedNames() {
        let authors = CitationAuthor.parse(from: "John Smith & Jane Doe")
        XCTAssertEqual(authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    func testParsesMiddleNameIntoGiven() {
        let authors = CitationAuthor.parse(from: "John Michael Smith")
        XCTAssertEqual(authors, [CitationAuthor(given: "John Michael", family: "Smith")])
    }

    func testEmptyAuthorsParseToEmptyList() {
        XCTAssertEqual(CitationAuthor.parse(from: nil), [])
        XCTAssertEqual(CitationAuthor.parse(from: "   "), [])
    }

    func testInitialsNormaliseSpacedAndDottedGivenNames() {
        XCTAssertEqual(CitationAuthor(given: "John Michael", family: "X").initials, "J. M.")
        XCTAssertEqual(CitationAuthor(given: "J.M.", family: "X").initials, "J. M.")
        XCTAssertEqual(CitationAuthor(given: nil, family: "X").initials, "")
    }

    // MARK: - APA

    func testAPASingleAuthorWithAllFields() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "A Study of Things",
            year: 2020,
            container: "Journal of Things",
            volume: "12",
            issue: "3",
            pages: "45-67",
            doi: "10.1/abc"
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertEqual(
            out,
            "Smith, J. (2020). A Study of Things. *Journal of Things*, *12*(3), 45-67. https://doi.org/10.1/abc"
        )
    }

    func testAPATwoAuthorsUseAmpersand() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "John", family: "Smith"),
                CitationAuthor(given: "Jane", family: "Doe")
            ],
            title: "Paper",
            year: 2021
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertTrue(out.contains("Smith, J., & Doe, J."), out)
    }

    func testAPAThreeAuthorsUseSerialAmpersand() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "A", family: "One"),
                CitationAuthor(given: "B", family: "Two"),
                CitationAuthor(given: "C", family: "Three")
            ],
            title: "Paper"
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertTrue(out.contains("One, A., Two, B., & Three, C."), out)
    }

    func testAPAOmitsMissingYearAndJournalGracefully() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Untitled Work",
            doi: "10.5/xyz"
        )
        let out = CitationFormatter.format(m, style: .apa)
        // No "()" year block, no journal, but title + DOI present.
        XCTAssertFalse(out.contains("("), out)
        XCTAssertEqual(out, "Smith, J. Untitled Work. https://doi.org/10.5/xyz")
    }

    func testAPAWithArxivFallsBackToPreprintAndArxivURL() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Deep Nets",
            year: 2019,
            arxivId: "1901.01234"
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertTrue(out.contains("*arXiv preprint*."), out)
        XCTAssertTrue(out.contains("https://arxiv.org/abs/1901.01234"), out)
    }

    func testAPADoesNotDoubleTerminalTitlePeriod() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "A", family: "One")],
            title: "Is it a question?"
        )
        let out = CitationFormatter.format(m, style: .apa)
        XCTAssertTrue(out.contains("Is it a question?"), out)
        XCTAssertFalse(out.contains("question?."), out)
    }

    // MARK: - MLA

    func testMLASingleAuthor() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "A Study",
            year: 2020,
            container: "Journal of Things"
        )
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertTrue(out.hasPrefix("Smith, John. \u{201C}A Study.\u{201D}"), out)
        XCTAssertTrue(out.contains("*Journal of Things*"), out)
        XCTAssertTrue(out.contains("2020"), out)
    }

    func testMLATwoAuthorsSecondInNaturalOrder() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "John", family: "Smith"),
                CitationAuthor(given: "Jane", family: "Doe")
            ],
            title: "Paper"
        )
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertTrue(out.hasPrefix("Smith, John, and Jane Doe."), out)
    }

    func testMLAThreeOrMoreUsesEtAl() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "A", family: "One"),
                CitationAuthor(given: "B", family: "Two"),
                CitationAuthor(given: "C", family: "Three")
            ],
            title: "Paper"
        )
        let out = CitationFormatter.format(m, style: .mla)
        XCTAssertTrue(out.hasPrefix("One, A, et al."), out)
    }

    // MARK: - Chicago

    func testChicagoSingleAuthorWithJournal() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "A Study",
            year: 2020,
            container: "Journal of Things",
            volume: "12",
            issue: "3",
            pages: "45-67"
        )
        let out = CitationFormatter.format(m, style: .chicago)
        XCTAssertTrue(out.hasPrefix("Smith, John. \u{201C}A Study.\u{201D}"), out)
        XCTAssertTrue(out.contains("*Journal of Things* 12, no. 3 (2020): 45-67."), out)
    }

    func testChicagoTwoAuthors() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "John", family: "Smith"),
                CitationAuthor(given: "Jane", family: "Doe")
            ],
            title: "Paper"
        )
        let out = CitationFormatter.format(m, style: .chicago)
        XCTAssertTrue(out.hasPrefix("Smith, John, and Jane Doe."), out)
    }

    // MARK: - BibTeX

    func testBibTeXArticleWithCiteKey() {
        let m = CitationMetadata(
            authors: [
                CitationAuthor(given: "John", family: "Smith"),
                CitationAuthor(given: "Jane", family: "Doe")
            ],
            title: "Deep Learning Methods",
            year: 2020,
            container: "Journal of Things",
            doi: "10.1/abc"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@article{smith2020deep,"), out)
        XCTAssertTrue(out.contains("author = {Smith, John and Doe, Jane}"), out)
        XCTAssertTrue(out.contains("title = {Deep Learning Methods}"), out)
        XCTAssertTrue(out.contains("journal = {Journal of Things}"), out)
        XCTAssertTrue(out.contains("year = {2020}"), out)
        XCTAssertTrue(out.contains("doi = {10.1/abc}"), out)
    }

    func testBibTeXMiscWhenNoJournalAndArxivEprint() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "Preprint",
            year: 2019,
            arxivId: "1901.01234"
        )
        let out = CitationFormatter.format(m, style: .bibtex)
        XCTAssertTrue(out.hasPrefix("@misc{"), out)
        XCTAssertTrue(out.contains("eprint = {1901.01234}"), out)
        XCTAssertTrue(out.contains("archivePrefix = {arXiv}"), out)
    }

    // MARK: - RIS

    func testRISContainsExpectedTags() {
        let m = CitationMetadata(
            authors: [CitationAuthor(given: "John", family: "Smith")],
            title: "A Study",
            year: 2020,
            container: "Journal of Things",
            doi: "10.1/abc"
        )
        let out = CitationFormatter.format(m, style: .ris)
        XCTAssertTrue(out.contains("TY  - JOUR"), out)
        XCTAssertTrue(out.contains("AU  - Smith, John"), out)
        XCTAssertTrue(out.contains("TI  - A Study"), out)
        XCTAssertTrue(out.contains("PY  - 2020"), out)
        XCTAssertTrue(out.contains("JO  - Journal of Things"), out)
        XCTAssertTrue(out.contains("DO  - 10.1/abc"), out)
        XCTAssertTrue(out.hasSuffix("ER  - "), out)
    }

    // MARK: - Metadata assembly from Paper

    func testMetadataFromPaperParsesAuthorsAndFields() {
        let paper = Paper(
            title: "  A Study of Things  ",
            authors: "John Smith, Jane Doe",
            doi: " 10.1/abc ",
            arxivId: "",
            filePath: "x.pdf"
        )
        let m = CitationMetadata(paper: paper)
        XCTAssertEqual(m.title, "A Study of Things")
        XCTAssertEqual(m.doi, "10.1/abc")
        XCTAssertNil(m.arxivId)
        XCTAssertEqual(m.authors, [
            CitationAuthor(given: "John", family: "Smith"),
            CitationAuthor(given: "Jane", family: "Doe")
        ])
    }

    // MARK: - Enrichment merge (offline, deterministic)

    func testCrossRefMergeOverlaysFields() {
        let fallback = CitationMetadata(
            authors: [CitationAuthor(given: "Old", family: "Author")],
            title: "Old Title",
            doi: "10.1/abc"
        )
        let message: [String: Any] = [
            "author": [
                ["given": "John", "family": "Smith"],
                ["given": "Jane", "family": "Doe"]
            ],
            "title": ["Real Title"],
            "container-title": ["Journal of Things"],
            "volume": "12",
            "issue": "3",
            "page": "45-67",
            "publisher": "ACME",
            "published-print": ["date-parts": [[2020, 6, 1]]]
        ]
        let merged = CitationMetadataService.mergeCrossRef(message, into: fallback)
        XCTAssertEqual(merged.title, "Real Title")
        XCTAssertEqual(merged.container, "Journal of Things")
        XCTAssertEqual(merged.year, 2020)
        XCTAssertEqual(merged.volume, "12")
        XCTAssertEqual(merged.issue, "3")
        XCTAssertEqual(merged.pages, "45-67")
        XCTAssertEqual(merged.publisher, "ACME")
        XCTAssertEqual(merged.doi, "10.1/abc")
        XCTAssertEqual(merged.authors.count, 2)
        XCTAssertEqual(merged.authors.first?.family, "Smith")
    }

    func testCrossRefMergeKeepsFallbackWhenFieldsAbsent() {
        let fallback = CitationMetadata(
            authors: [CitationAuthor(given: "Old", family: "Author")],
            title: "Kept Title",
            doi: "10.1/abc"
        )
        let merged = CitationMetadataService.mergeCrossRef([:], into: fallback)
        XCTAssertEqual(merged.title, "Kept Title")
        XCTAssertEqual(merged.authors, fallback.authors)
    }

    func testArxivMergeFillsFieldsAndDefaultsContainer() {
        let fallback = CitationMetadata(
            authors: [],
            title: nil,
            arxivId: "1901.01234"
        )
        let entry = ArxivEntry(
            title: "Deep\n  Nets",
            authors: ["John Smith", "Jane Doe"],
            year: 2019,
            journalRef: nil,
            doi: nil
        )
        let merged = CitationMetadataService.mergeArxiv(entry, arxivId: "1901.01234", into: fallback)
        XCTAssertEqual(merged.title, "Deep Nets")
        XCTAssertEqual(merged.year, 2019)
        XCTAssertEqual(merged.container, "arXiv")
        XCTAssertEqual(merged.authors.count, 2)
        XCTAssertEqual(merged.authors.first, CitationAuthor(given: "John", family: "Smith"))
    }

    func testArxivAtomParserExtractsEntry() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
          <title>ArXiv Query</title>
          <entry>
            <title>Attention Is All You Need</title>
            <published>2017-06-12T17:57:34Z</published>
            <author><name>Ashish Vaswani</name></author>
            <author><name>Noam Shazeer</name></author>
            <arxiv:journal_ref>NeurIPS 2017</arxiv:journal_ref>
          </entry>
        </feed>
        """
        let entry = ArxivAtomParser().parse(Data(xml.utf8))
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.title, "Attention Is All You Need")
        XCTAssertEqual(entry?.year, 2017)
        XCTAssertEqual(entry?.authors, ["Ashish Vaswani", "Noam Shazeer"])
        XCTAssertEqual(entry?.journalRef, "NeurIPS 2017")
    }
}
