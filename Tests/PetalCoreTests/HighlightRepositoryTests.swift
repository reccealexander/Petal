import XCTest
import GRDB
@testable import PetalCore

/// Exercises `HighlightRepository`'s public API: ordered fetch, comment
/// upsert semantics, the commented-ids projection, and cascade delete.
final class HighlightRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repo: HighlightRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        repo = HighlightRepository(database: manager)
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

    private func makeHighlight(paperId: String, page: Int, text: String) -> Highlight {
        Highlight(paperId: paperId, page: page, boundingBoxes: "[]", color: "yellow", selectedText: text)
    }

    // MARK: - Tests

    func testInsertAndFetchHighlightsOrderedByPage() throws {
        let paper = try insertPaper()
        let highlightOnPageTwo = makeHighlight(paperId: paper.id, page: 2, text: "second page text")
        let highlightOnPageZero = makeHighlight(paperId: paper.id, page: 0, text: "first page text")

        try repo.insertHighlights([highlightOnPageTwo, highlightOnPageZero])

        let fetched = try repo.highlights(forPaper: paper.id)

        XCTAssertEqual(fetched.count, 2)
        XCTAssertEqual(fetched.map(\.page), [0, 2], "Highlights should be ordered by page ascending")
        XCTAssertEqual(fetched.first?.id, highlightOnPageZero.id)
        XCTAssertEqual(fetched.last?.id, highlightOnPageTwo.id)
    }

    func testUpsertCommentCreatesThenUpdates() throws {
        let paper = try insertPaper()
        let highlight = makeHighlight(paperId: paper.id, page: 0, text: "some text")
        try repo.insertHighlights([highlight])

        XCTAssertNil(try repo.comment(forHighlight: highlight.id))

        let created = try repo.upsertComment(highlightId: highlight.id, paperId: paper.id, body: "first")
        XCTAssertEqual(created.body, "first")

        let fetchedAfterCreate = try repo.comment(forHighlight: highlight.id)
        XCTAssertEqual(fetchedAfterCreate?.body, "first")

        try repo.upsertComment(highlightId: highlight.id, paperId: paper.id, body: "second")

        let fetchedAfterUpdate = try repo.comment(forHighlight: highlight.id)
        XCTAssertEqual(fetchedAfterUpdate?.body, "second")
        XCTAssertNotNil(fetchedAfterUpdate?.updatedAt)

        let commentCount = try manager.dbQueue.read { db in
            try Comment.filter(Column("highlight_id") == highlight.id).fetchCount(db)
        }
        XCTAssertEqual(commentCount, 1, "Upsert should update the existing row, not create a second one")
    }

    func testCommentedHighlightIdsReflectsOnlyCommentedOnes() throws {
        let paper = try insertPaper()
        let highlightOne = makeHighlight(paperId: paper.id, page: 0, text: "highlight one")
        let highlightTwo = makeHighlight(paperId: paper.id, page: 1, text: "highlight two")
        try repo.insertHighlights([highlightOne, highlightTwo])

        try repo.upsertComment(highlightId: highlightOne.id, paperId: paper.id, body: "commented")

        let commentedIds = try repo.commentedHighlightIds(forPaper: paper.id)

        XCTAssertEqual(commentedIds, [highlightOne.id])
        XCTAssertTrue(commentedIds.contains(highlightOne.id))
        XCTAssertFalse(commentedIds.contains(highlightTwo.id))
    }

    func testDeleteCommentLeavesHighlightAndRemovesCommentIndicator() throws {
        let paper = try insertPaper()
        let highlight = makeHighlight(paperId: paper.id, page: 0, text: "highlight remains")
        try repo.insertHighlights([highlight])
        let comment = try repo.upsertComment(
            highlightId: highlight.id,
            paperId: paper.id,
            body: "comment to delete"
        )

        try repo.deleteComment(forHighlight: highlight.id)

        XCTAssertNil(try repo.comment(forHighlight: highlight.id))
        XCTAssertEqual(try repo.highlights(forPaper: paper.id).map(\.id), [highlight.id])
        XCTAssertFalse(try repo.commentedHighlightIds(forPaper: paper.id).contains(highlight.id))
        let indexedCommentCount = try manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?",
                arguments: [comment.id]
            )
        }
        XCTAssertEqual(indexedCommentCount, 0)
    }

    func testDeleteHighlightCascadesItsComment() throws {
        let paper = try insertPaper()
        let highlight = makeHighlight(paperId: paper.id, page: 0, text: "text to delete")
        try repo.insertHighlights([highlight])
        try repo.upsertComment(highlightId: highlight.id, paperId: paper.id, body: "a comment")

        XCTAssertNotNil(try repo.comment(forHighlight: highlight.id))

        try repo.deleteHighlight(id: highlight.id)

        let remainingHighlights = try repo.highlights(forPaper: paper.id)
        XCTAssertTrue(remainingHighlights.isEmpty)

        let remainingComments = try manager.dbQueue.read { db in
            try Comment.fetchCount(db)
        }
        XCTAssertEqual(remainingComments, 0, "Deleting a highlight should cascade-delete its comment")
    }
}
