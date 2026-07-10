import XCTest
import GRDB
@testable import PaperReaderCore

/// Exercises `NoteRepository`'s public API: lazy create-or-load of the
/// primary note, save semantics, and the linked-highlight-ids JSON codec.
final class NoteRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repo: NoteRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        repo = NoteRepository(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
        repo = nil
    }

    // MARK: - Helpers

    private func insertPaper() throws -> Paper {
        let paper = Paper(filePath: "\(UUID().uuidString).pdf")
        try manager.dbQueue.write { try paper.insert($0) }
        return paper
    }

    // MARK: - Tests

    func testLoadOrCreateCreatesLazilyThenReturnsSame() throws {
        let paper = try insertPaper()

        XCTAssertNil(try repo.primaryNote(forPaper: paper.id))

        let created = try repo.loadOrCreatePrimaryNote(forPaper: paper.id, title: "Notes")
        XCTAssertEqual(created.paperId, paper.id)

        let countAfterCreate = try manager.dbQueue.read { db in
            try Note.filter(Column("paper_id") == paper.id).fetchCount(db)
        }
        XCTAssertEqual(countAfterCreate, 1, "Should create exactly one note row")

        let loadedAgain = try repo.loadOrCreatePrimaryNote(forPaper: paper.id, title: "Notes")
        XCTAssertEqual(loadedAgain.id, created.id, "Should return the same note, not create a second one")

        let countAfterSecondLoad = try manager.dbQueue.read { db in
            try Note.filter(Column("paper_id") == paper.id).fetchCount(db)
        }
        XCTAssertEqual(countAfterSecondLoad, 1, "A second load-or-create should not create another note row")
    }

    func testSavePersistsBodyAndLinkedIds() throws {
        let paper = try insertPaper()
        let created = try repo.loadOrCreatePrimaryNote(forPaper: paper.id, title: "Notes")

        var copy = created
        copy.body = "synthesis notes"
        copy.linkedHighlightIds = NoteRepository.encodeLinkedIds(["h1", "h2"])

        try repo.save(copy)

        let fetched = try repo.primaryNote(forPaper: paper.id)
        XCTAssertEqual(fetched?.body, "synthesis notes")
        XCTAssertNotNil(fetched?.updatedAt)
        XCTAssertEqual(NoteRepository.decodeLinkedIds(fetched?.linkedHighlightIds), ["h1", "h2"])
    }

    func testLinkedIdsCodecRoundTrips() {
        XCTAssertEqual(
            NoteRepository.decodeLinkedIds(NoteRepository.encodeLinkedIds(["a", "b", "c"])),
            ["a", "b", "c"]
        )
        XCTAssertEqual(NoteRepository.decodeLinkedIds(nil), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds("not json"), [])
        XCTAssertEqual(NoteRepository.decodeLinkedIds(NoteRepository.encodeLinkedIds([])), [])
    }
}
