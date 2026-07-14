import XCTest
import GRDB
@testable import PetalCore

/// Regressions for the sync data-loss bugs found in the codebase bug hunt:
/// C1 — `INSERT OR REPLACE` cascade-wiped children on a pulled parent update;
/// H2 — a pull overwrote an unpushed dirty local edit and cleared its dirty flag.
final class SyncFixRegressionTests: XCTestCase {
    private var manager: DatabaseManager!
    private var store: SyncStateStore!
    private var notes: NoteRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        store = SyncStateStore(database: manager)
        notes = NoteRepository(database: manager)
    }

    /// C1: applying a pulled UPDATE to an already-present parent must update the
    /// row in place and keep its cascade children (not delete-then-insert).
    func testApplyPulledParentUpdateKeepsChildren() throws {
        let paperId = UUID().uuidString
        try manager.dbQueue.write { db in
            try Paper(id: paperId, filePath: "p.pdf").insert(db)
            try Highlight(id: "h1", paperId: paperId, page: 0, boundingBoxes: "[]", selectedText: "keep me").insert(db)
        }
        // Mark the paper as already synced so the pulled update actually applies
        // (an unsynced/dirty paper would be skipped by the H2 guard).
        try store.markUploaded(saved: [SyncRecordID(recordType: "paper", recordName: paperId): "srv-0"], deleted: [])

        try store.applyPulled(SyncPullResult(changed: [SyncRecord(
            id: SyncRecordID(recordType: "paper", recordName: paperId),
            fields: ["id": .string(paperId), "file_path": .string("p.pdf"),
                     "title": .string("updated"), "reading_status": .string("unread"),
                     "furthest_page_read": .int(0)],
            changeTag: "srv-1")]))

        let hlCount = try manager.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM highlight WHERE id = 'h1'") ?? -1
        }
        XCTAssertEqual(hlCount, 1, "pulled paper update must not cascade-delete its highlight")
        let title = try manager.dbQueue.read {
            try String.fetchOne($0, sql: "SELECT title FROM paper WHERE id = ?", arguments: [paperId])
        }
        XCTAssertEqual(title, "updated", "the paper row must be updated in place")
    }

    /// H2: a pull must not overwrite a dirty (unpushed) local edit; it stays
    /// queued for push, where conflict resolution decides the winner.
    func testPullDoesNotClobberDirtyLocalEdit() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "t")
        var edited = note
        edited.body = "LOCAL UNPUSHED EDIT"
        try notes.save(edited)

        try store.applyPulled(SyncPullResult(changed: [SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: note.id),
            fields: ["id": .string(note.id), "body": .string("stale server body"),
                     "linked_highlight_ids": .string("[]"),
                     "updated_at": .string("2000-01-01 00:00:00.000")],
            changeTag: "srv")]))

        XCTAssertEqual(try notes.note(id: note.id)?.body, "LOCAL UNPUSHED EDIT",
                       "pull must not overwrite an unpushed local edit")
        XCTAssertTrue(try store.pendingUploads().contains { $0.id.recordName == note.id },
                      "the dirty local edit must remain queued for push")
    }
}
