import XCTest
import GRDB
@testable import PaperReaderCore

/// Exercises `SearchRepository` + `SearchIndex`: direct paper indexing, and the
/// indexing side effects of `NoteRepository.save` and
/// `HighlightRepository.upsertComment`.
final class SearchRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var searchRepo: SearchRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        searchRepo = SearchRepository(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        searchRepo = nil
    }

    // MARK: - Helpers

    private func insertPaper(title: String? = nil) throws -> Paper {
        let paper = Paper(title: title, filePath: "\(UUID().uuidString).pdf")
        try manager.dbQueue.write { try paper.insert($0) }
        return paper
    }

    // MARK: - Tests

    func testIndexAndSearchPaper() throws {
        let paper = Paper(title: "Graphene Superconductivity", filePath: "\(UUID().uuidString).pdf")

        try manager.dbQueue.write { db in
            try SearchIndex.indexPaper(paper, in: db)
        }

        let results = try searchRepo.search("graphene")
        XCTAssertFalse(results.isEmpty)

        let match = try XCTUnwrap(results.first { $0.id == paper.id })
        XCTAssertEqual(match.entityType, .paper)
        XCTAssertEqual(match.id, paper.id)
    }

    func testNoteSaveIsIndexed() throws {
        let paper = try insertPaper()
        let noteRepo = NoteRepository(database: manager)

        var note = try noteRepo.loadOrCreatePrimaryNote(forPaper: paper.id, title: nil)
        // This mirrors NotesViewModel.saveNow(): RTF is canonical, while its
        // plain-text extraction is saved in body for SearchIndex/FTS.
        note.bodyRtf = Data("{\\rtf1\\ansi quantum tunneling notes}".utf8)
        note.body = "quantum tunneling notes"
        try noteRepo.save(note)

        let results = try searchRepo.search("quantum")
        let match = try XCTUnwrap(results.first { $0.entityType == .note })
        XCTAssertEqual(match.id, note.id)
        XCTAssertEqual(try noteRepo.note(id: note.id)?.bodyRtf, note.bodyRtf)
    }

    func testCommentSaveIsIndexed() throws {
        let paper = try insertPaper()
        let highlightRepo = HighlightRepository(database: manager)
        let highlight = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "some text")
        try highlightRepo.insertHighlights([highlight])

        try highlightRepo.upsertComment(highlightId: highlight.id, paperId: paper.id, body: "important caveat")

        let results = try searchRepo.search("caveat")
        XCTAssertTrue(results.contains { $0.entityType == .comment })
    }

    func testBlankQueryReturnsEmpty() throws {
        XCTAssertEqual(try searchRepo.search(""), [])
        XCTAssertEqual(try searchRepo.search("   "), [])
    }
}
