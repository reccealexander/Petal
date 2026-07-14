import XCTest
import GRDB
@testable import PetalCore

/// Exercises the three schema behaviours Session 1 must guarantee:
/// recursive notebook traversal, cascade deletes, and FTS5 search.
final class DatabaseLayerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
    }

    override func tearDownWithError() throws {
        manager = nil
    }

    // MARK: - Migrations sanity

    func testMigrationsAreApplied() throws {
        let applied = try manager.appliedMigrations()
        XCTAssertEqual(applied, ["v1_initial_schema", "v2_add_file_hash", "v3_add_notebook_summary", "v4_add_free_space_position", "v5_add_pinned_at", "v6_add_page_bookmark", "v7_add_reading_progress", "v8_add_furthest_page_read", "v9_add_note_rtf", "v10_add_notebook_summary_paper_set", "v11_add_sync_state"])
    }

    func testForeignKeysAreEnabled() throws {
        let enabled = try dbQueue.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(enabled, true, "Foreign keys must be ON for cascade/set-null to work")
    }

    // MARK: - Recursive notebook query (spec §1 WITH RECURSIVE CTE)

    func testRecursiveFetchOfPapersUnderNestedNotebooks() throws {
        // Research > 2D Materials > Graphene, plus an unrelated notebook.
        let research = Notebook(name: "Research")
        let materials = Notebook(name: "2D Materials", parentId: research.id)
        let graphene = Notebook(name: "Graphene", parentId: materials.id)
        let unrelated = Notebook(name: "Unrelated")

        // One paper directly in a child, one two levels deep, one outside the tree.
        let paperInChild = Paper(notebookId: materials.id, filePath: "materials.pdf")
        let paperInGrandchild = Paper(notebookId: graphene.id, filePath: "graphene.pdf")
        let paperOutside = Paper(notebookId: unrelated.id, filePath: "unrelated.pdf")

        try dbQueue.write { db in
            for notebook in [research, materials, graphene, unrelated] {
                try notebook.insert(db)
            }
            for paper in [paperInChild, paperInGrandchild, paperOutside] {
                try paper.insert(db)
            }
        }

        let papers = try papersUnderNotebook(id: research.id)
        let ids = Set(papers.map(\.id))

        XCTAssertEqual(papers.count, 2, "Should include papers from all descendant notebooks")
        XCTAssertTrue(ids.contains(paperInChild.id))
        XCTAssertTrue(ids.contains(paperInGrandchild.id))
        XCTAssertFalse(ids.contains(paperOutside.id), "Papers outside the subtree must be excluded")
    }

    /// The exact `WITH RECURSIVE` traversal from spec §1.
    private func papersUnderNotebook(id rootId: String) throws -> [Paper] {
        try dbQueue.read { db in
            try Paper.fetchAll(db, sql: """
                WITH RECURSIVE sub_notebooks(id) AS (
                    SELECT id FROM notebook WHERE id = ?
                    UNION ALL
                    SELECT n.id FROM notebook n
                    JOIN sub_notebooks s ON n.parent_id = s.id
                )
                SELECT * FROM paper WHERE notebook_id IN (SELECT id FROM sub_notebooks)
                """, arguments: [rootId])
        }
    }

    // MARK: - Cascade delete (paper -> highlights -> comments)

    func testDeletingPaperCascadesToHighlightsAndComments() throws {
        let paper = Paper(filePath: "cascade.pdf")
        let highlight = Highlight(
            paperId: paper.id,
            page: 1,
            boundingBoxes: "[]",
            selectedText: "attention is all you need"
        )
        // A comment linked to the highlight, and a second comment linked to the
        // paper directly — both should disappear when the paper is deleted.
        let commentOnHighlight = Comment(highlightId: highlight.id, paperId: paper.id, body: "great point")
        let commentOnPaper = Comment(paperId: paper.id, body: "paper-level note")

        try dbQueue.write { db in
            try paper.insert(db)
            try highlight.insert(db)
            try commentOnHighlight.insert(db)
            try commentOnPaper.insert(db)
        }

        try assertCounts(highlights: 1, comments: 2)

        // Delete the paper; cascade should remove everything beneath it.
        try dbQueue.write { db in
            let deleted = try paper.delete(db)
            XCTAssertTrue(deleted)
        }

        try assertCounts(highlights: 0, comments: 0)
    }

    private func assertCounts(highlights: Int, comments: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        try dbQueue.read { db in
            XCTAssertEqual(try Highlight.fetchCount(db), highlights, "highlight count", file: file, line: line)
            XCTAssertEqual(try Comment.fetchCount(db), comments, "comment count", file: file, line: line)
        }
    }

    // MARK: - FTS5 full-text search

    func testFullTextSearchReturnsMatchingEntity() throws {
        let paperId = UUID().uuidString
        let grapheneHighlightId = UUID().uuidString
        let transformerHighlightId = UUID().uuidString

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO search_index (entity_id, entity_type, paper_id, content) VALUES (?, ?, ?, ?)",
                arguments: [grapheneHighlightId, "highlight", paperId, "graphene has remarkable electronic properties"]
            )
            try db.execute(
                sql: "INSERT INTO search_index (entity_id, entity_type, paper_id, content) VALUES (?, ?, ?, ?)",
                arguments: [transformerHighlightId, "highlight", paperId, "the transformer architecture uses self attention"]
            )
        }

        // Search for a term unique to the first row.
        let matches = try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT entity_id FROM search_index WHERE search_index MATCH ? ORDER BY rank",
                arguments: ["graphene"]
            )
        }

        XCTAssertEqual(matches, [grapheneHighlightId], "FTS5 should return exactly the matching entity")

        // A term matching neither row returns nothing.
        let empty = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT entity_id FROM search_index WHERE search_index MATCH ?", arguments: ["quantum"])
        }
        XCTAssertTrue(empty.isEmpty)
    }
}
