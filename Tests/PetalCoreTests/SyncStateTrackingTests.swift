import XCTest
import GRDB
@testable import PetalCore

/// Verifies the V11 automatic change-tracking triggers and `SyncStateStore`'s
/// generic materialize / apply / suppression behavior.
final class SyncStateTrackingTests: XCTestCase {
    private var manager: DatabaseManager!
    private var store: SyncStateStore!
    private var notes: NoteRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        store = SyncStateStore(database: manager)
        notes = NoteRepository(database: manager)
    }

    func testInsertViaRepositoryMarksRowDirty() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Hello")

        let uploads = try store.pendingUploads()
        let mine = try XCTUnwrap(uploads.first { $0.id.recordName == note.id })
        XCTAssertEqual(mine.id.recordType, "note")
        XCTAssertEqual(mine.fields["id"], .string(note.id))
        XCTAssertEqual(mine.fields["body"], .string(""))
        // A brand-new local row has no server change tag yet.
        XCTAssertNil(mine.changeTag)
    }

    func testDeleteViaRepositoryCreatesTombstone() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Doomed")
        try notes.deleteNote(id: note.id)

        let deletions = try store.pendingDeletions()
        XCTAssertTrue(deletions.contains(SyncRecordID(recordType: "note", recordName: note.id)))
        // A tombstone is not also offered as an upload.
        XCTAssertFalse(try store.pendingUploads().contains { $0.id.recordName == note.id })
    }

    func testApplyPulledInsertsRowWithoutMarkingItDirty() throws {
        let id = UUID().uuidString
        let record = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: [
                "id": .string(id),
                "body": .string("pulled body"),
                "linked_highlight_ids": .string("[]"),
            ],
            changeTag: "srv-1"
        )
        let token = SyncChangeToken(data: Data([1, 2, 3]))

        try store.applyPulled(SyncPullResult(changed: [record], newToken: token))

        // Row landed locally...
        let applied = try XCTUnwrap(try notes.note(id: id))
        XCTAssertEqual(applied.body, "pulled body")
        // ...but suppression means it is NOT re-queued for upload...
        XCTAssertFalse(try store.pendingUploads().contains { $0.id.recordName == id })
        // ...its server change tag is recorded, and the token advanced.
        XCTAssertEqual(try store.changeToken(), token)
        // FTS was rebuilt for the pulled note.
        let indexed = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?", arguments: [id]) ?? 0
        }
        XCTAssertEqual(indexed, 1)
    }

    func testApplyPulledDeletionRemovesRowAndIndex() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Bye")
        try store.applyPulled(
            SyncPullResult(deleted: [SyncRecordID(recordType: "note", recordName: note.id)])
        )
        XCTAssertNil(try notes.note(id: note.id))
        let indexed = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?", arguments: [note.id]) ?? 0
        }
        XCTAssertEqual(indexed, 0)
    }

    func testCompositeKeyEntityRoundTrips() throws {
        // paper_tag uses a composite recordName "paper_id:tag_id".
        let paperId = UUID().uuidString
        let tagId = UUID().uuidString
        let recordName = "\(paperId):\(tagId)"
        let entity = try XCTUnwrap(SyncedEntity.lookup("paper_tag"))
        XCTAssertEqual(entity.keyValues(fromRecordName: recordName), [paperId, tagId])
    }
}
