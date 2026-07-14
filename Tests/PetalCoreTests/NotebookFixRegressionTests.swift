import XCTest
import GRDB
@testable import PetalCore

/// Regressions for the notebook-deletion bugs (H1) and the cyclic-graph CTE
/// hang (M2) found in the codebase bug hunt.
final class NotebookFixRegressionTests: XCTestCase {
    private var manager: DatabaseManager!
    private var notebooks: NotebookRepository!
    private var notes: NoteRepository!
    private var chat: ChatSessionRepository!
    private var search: SearchRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        notebooks = NotebookRepository(database: manager)
        notes = NoteRepository(database: manager)
        chat = ChatSessionRepository(database: manager)
        search = SearchRepository(database: manager)
    }

    /// H1: deleting a notebook removes the FTS rows of its cascade-deleted
    /// notebook-scoped notes (and its descendants').
    func testDeletingNotebookRemovesItsNotesFTSRows() throws {
        let parent = try notebooks.create(name: "Parent", parentId: nil)
        let child = try notebooks.create(name: "Child", parentId: parent.id)
        let n1 = try notes.createNote(paperId: nil, notebookId: parent.id, title: "p note")
        var e1 = n1; e1.body = "photosynthesis chloroplast"; try notes.save(e1)
        let n2 = try notes.createNote(paperId: nil, notebookId: child.id, title: "c note")
        var e2 = n2; e2.body = "mitochondria respiration"; try notes.save(e2)

        try notebooks.delete(id: parent.id)

        XCTAssertNil(try notes.note(id: n1.id))
        XCTAssertNil(try notes.note(id: n2.id))
        XCTAssertTrue(try search.search("photosynthesis").isEmpty, "parent-note FTS row leaked")
        XCTAssertTrue(try search.search("mitochondria").isEmpty, "descendant-note FTS row leaked")
    }

    /// H1: deleting a notebook removes its (and descendants') notebook-scoped
    /// chat_session rows (no FK, so they'd otherwise orphan).
    func testDeletingNotebookRemovesItsChatSessions() throws {
        let nb = try notebooks.create(name: "NB", parentId: nil)
        _ = try chat.saveMessages([ChatMessage(role: "user", content: "hi", timestamp: Date(timeIntervalSince1970: 1))],
                                  scope: .notebook, scopeId: nb.id)
        try notebooks.delete(id: nb.id)
        let count = try manager.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_session WHERE scope = 'notebook' AND scope_id = ?",
                             arguments: [nb.id]) ?? -1
        }
        XCTAssertEqual(count, 0, "notebook chat_session rows leaked on delete")
    }

    /// M2: a cyclic notebook graph (e.g. produced by concurrent sync re-parents)
    /// must not hang the recursive traversal CTE — UNION terminates it.
    func testTraversalTerminatesOnCyclicGraph() throws {
        let a = Notebook(name: "A")
        let b = Notebook(name: "B", parentId: a.id)
        try manager.dbQueue.write { db in
            try a.insert(db)
            try b.insert(db)
            // Close the loop: A.parent = B, B.parent = A.
            try db.execute(sql: "UPDATE notebook SET parent_id = ? WHERE id = ?", arguments: [b.id, a.id])
        }
        // Would spin forever with UNION ALL; UNION dedups and terminates.
        let papers = try notebooks.papersUnder(notebookId: a.id)
        XCTAssertTrue(papers.isEmpty)
    }
}
