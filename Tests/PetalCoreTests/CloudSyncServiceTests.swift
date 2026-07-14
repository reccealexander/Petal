import XCTest
import GRDB
@testable import PetalCore

/// A fake `CloudKitBackend` that records what it was asked to save/delete and
/// replays scripted pull results and conflicts, so `CloudSyncService`'s push /
/// pull / conflict logic is testable with no live CloudKit.
private actor FakeCloudKitBackend: CloudKitBackend {
    private(set) var savedRecords: [SyncRecord] = []
    private(set) var deletedIDs: [SyncRecordID] = []
    private(set) var ensureZoneCalls = 0

    private var tagToAssign = "srv"
    private var conflictsToReturn: [SyncConflict] = []
    private var pullResults: [SyncPullResult] = []
    private var pullIndex = 0

    func setPullResults(_ results: [SyncPullResult]) { pullResults = results }
    func setConflicts(_ conflicts: [SyncConflict]) { conflictsToReturn = conflicts }

    func ensureZone() async throws { ensureZoneCalls += 1 }

    func save(records: [SyncRecord], deletions: [SyncRecordID]) async throws -> SyncPushResult {
        savedRecords.append(contentsOf: records)
        deletedIDs.append(contentsOf: deletions)
        // Conflicted records are NOT saved (mirrors CloudKit's serverRecordChanged).
        let conflictedIDs = Set(conflictsToReturn.map(\.id))
        var tags: [SyncRecordID: String] = [:]
        for record in records where !conflictedIDs.contains(record.id) {
            tags[record.id] = tagToAssign
        }
        let conflicts = conflictsToReturn
        conflictsToReturn = [] // one-shot
        return SyncPushResult(savedChangeTags: tags, conflicts: conflicts)
    }

    func fetchChanges(since token: SyncChangeToken?) async throws -> SyncPullResult {
        guard pullIndex < pullResults.count else {
            return SyncPullResult(newToken: token, moreComing: false)
        }
        defer { pullIndex += 1 }
        return pullResults[pullIndex]
    }
}

final class CloudSyncServiceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var store: SyncStateStore!
    private var notes: NoteRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        store = SyncStateStore(database: manager)
        notes = NoteRepository(database: manager)
    }

    func testPushSavesDirtyRowsAndClearsTheirState() async throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Push me")
        let backend = FakeCloudKitBackend()
        let service = CloudSyncService(store: store, backend: backend)

        let pushed = try await service.push()

        XCTAssertEqual(pushed, 1)
        let saved = await backend.savedRecords
        XCTAssertTrue(saved.contains { $0.id.recordName == note.id })
        // Dirty flag cleared and server tag stored.
        XCTAssertTrue(try store.pendingUploads().isEmpty)
        let noteId = note.id
        let tag = try await manager.dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT ck_change_tag FROM sync_state WHERE entity_id = ?", arguments: [noteId]
            )
        }
        XCTAssertEqual(tag, "srv")
    }

    func testPushSendsTombstonesAsDeletions() async throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Delete me")
        try notes.deleteNote(id: note.id)
        let backend = FakeCloudKitBackend()
        let service = CloudSyncService(store: store, backend: backend)

        _ = try await service.push()

        let deleted = await backend.deletedIDs
        XCTAssertTrue(deleted.contains(SyncRecordID(recordType: "note", recordName: note.id)))
        // Tombstone consumed.
        XCTAssertTrue(try store.pendingDeletions().isEmpty)
    }

    func testPullAppliesChangesAndAdvancesToken() async throws {
        let id = UUID().uuidString
        let token = SyncChangeToken(data: Data([9, 9]))
        let record = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: ["id": .string(id), "body": .string("from server"), "linked_highlight_ids": .string("[]")],
            changeTag: "srv-a"
        )
        let backend = FakeCloudKitBackend()
        await backend.setPullResults([SyncPullResult(changed: [record], newToken: token, moreComing: false)])
        let service = CloudSyncService(store: store, backend: backend)

        let applied = try await service.pull()

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(try notes.note(id: id)?.body, "from server")
        XCTAssertEqual(try store.changeToken(), token)
    }

    func testSyncEnsuresZoneOnlyOnce() async throws {
        let backend = FakeCloudKitBackend()
        let service = CloudSyncService(store: store, backend: backend)

        _ = try await service.sync()
        _ = try await service.sync()

        let calls = await backend.ensureZoneCalls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(try store.zoneCreated())
    }

    func testConflictServerWinsWhenServerIsNewer() async throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Contested")
        var edited = note
        edited.body = "local edit"
        try notes.save(edited)

        let serverRecord = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: note.id),
            fields: ["id": .string(note.id), "body": .string("server edit"),
                     "updated_at": .string("2099-01-01 00:00:00.000")],
            changeTag: "srv-newer"
        )
        let attempted = SyncRecord(
            id: serverRecord.id,
            fields: ["id": .string(note.id), "body": .string("local edit"),
                     "updated_at": .string("2000-01-01 00:00:00.000")]
        )
        let backend = FakeCloudKitBackend()
        await backend.setConflicts([SyncConflict(id: serverRecord.id, attempted: attempted, server: serverRecord)])
        let service = CloudSyncService(store: store, backend: backend)

        _ = try await service.push()

        // Server was newer, so its body wins locally and the row is no longer dirty.
        XCTAssertEqual(try notes.note(id: note.id)?.body, "server edit")
        XCTAssertTrue(try store.pendingUploads().isEmpty)
    }

    func testConflictLocalWinsWhenLocalIsNewer() async throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "Contested")
        var edited = note
        edited.body = "local edit"
        try notes.save(edited)

        let serverRecord = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: note.id),
            fields: ["id": .string(note.id), "body": .string("stale server"),
                     "updated_at": .string("2000-01-01 00:00:00.000")],
            changeTag: "srv-older"
        )
        let attempted = SyncRecord(
            id: serverRecord.id,
            fields: ["id": .string(note.id), "body": .string("local edit"),
                     "updated_at": .string("2099-01-01 00:00:00.000")]
        )
        let backend = FakeCloudKitBackend()
        await backend.setConflicts([SyncConflict(id: serverRecord.id, attempted: attempted, server: serverRecord)])
        let service = CloudSyncService(store: store, backend: backend)

        _ = try await service.push()

        // Local was newer: DB keeps the local body and the re-save clears dirty.
        XCTAssertEqual(try notes.note(id: note.id)?.body, "local edit")
        XCTAssertTrue(try store.pendingUploads().isEmpty)
    }

    func testIsNewerOrdersByTimestamp() {
        let newer = SyncRecord(id: .init(recordType: "note", recordName: "a"),
                               fields: ["updated_at": .string("2026-05-05 00:00:00.000")])
        let older = SyncRecord(id: .init(recordType: "note", recordName: "a"),
                               fields: ["updated_at": .string("2026-01-01 00:00:00.000")])
        XCTAssertTrue(CloudSyncService.isNewer(newer, thanOrEqualTo: older))
        XCTAssertFalse(CloudSyncService.isNewer(older, thanOrEqualTo: newer))
    }
}
