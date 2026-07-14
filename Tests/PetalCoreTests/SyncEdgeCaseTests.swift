import XCTest
import GRDB
@testable import PetalCore

/// Adversarial edge-case coverage for the CloudKit sync layer:
/// `CloudSyncService` (conflict resolution, token paging), `SyncStateStore`
/// (generic materialize / apply / delete-ordering / suppression), and the
/// `SyncValue` round-trip through GRDB.
///
/// Every test here asserts the layer's *current, intended* behavior and passes.
/// (Separately-documented real bugs are reported out-of-band and are NOT encoded
/// as tests here.)
final class SyncEdgeCaseTests: XCTestCase {
    private var manager: DatabaseManager!
    private var store: SyncStateStore!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        store = SyncStateStore(database: manager)
    }

    // MARK: - Fixtures

    @discardableResult
    private func insertPaper(id: String = UUID().uuidString, title: String = "P") throws -> String {
        try manager.dbQueue.write { db in
            try Paper(id: id, title: title, filePath: "\(id).pdf").insert(db)
        }
        return id
    }

    @discardableResult
    private func insertTag(id: String = UUID().uuidString, name: String) throws -> String {
        try manager.dbQueue.write { db in try Tag(id: id, name: name).insert(db) }
        return id
    }

    private func suppressFlag() throws -> Int {
        try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT suppress FROM sync_control WHERE id = 0") ?? -1
        }
    }

    private func rowExists(_ table: String, key whereSQL: String, _ args: StatementArguments) throws -> Bool {
        try manager.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\" WHERE \(whereSQL)", arguments: args) ?? 0) > 0
        }
    }

    /// Synchronous helper so async tests don't bind GRDB's async `write` overload.
    private func setStoredToken(_ token: SyncChangeToken) throws {
        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_cursor SET server_change_token = ? WHERE id = 0",
                           arguments: [token.data])
        }
    }

    // MARK: - isNewer: missing / tied timestamps, both directions

    /// Tie on equal timestamps resolves to the local (attempted) record (`>=`).
    func testIsNewerEqualTimestampsFavorsLocal() {
        let a = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                           fields: ["updated_at": .string("2026-07-14 10:00:00.000")])
        let b = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                           fields: ["updated_at": .string("2026-07-14 10:00:00.000")])
        XCTAssertTrue(CloudSyncService.isNewer(a, thanOrEqualTo: b))
    }

    /// Neither side carries any known timestamp field: both extract to "" so the
    /// tie rule again favors local. (This is the degenerate LWW case for
    /// timestamp-less rows.)
    func testIsNewerBothMissingTimestampsFavorsLocal() {
        let a = SyncRecord(id: .init(recordType: "tag", recordName: "x"),
                           fields: ["id": .string("x"), "name": .string("local")])
        let b = SyncRecord(id: .init(recordType: "tag", recordName: "x"),
                           fields: ["id": .string("x"), "name": .string("server")])
        XCTAssertTrue(CloudSyncService.isNewer(a, thanOrEqualTo: b))
    }

    /// Only the local side has a timestamp -> local is treated as newer than the
    /// empty-string server timestamp.
    func testIsNewerOnlyLocalHasTimestampLocalWins() {
        let local = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                               fields: ["updated_at": .string("2000-01-01 00:00:00.000")])
        let server = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                                fields: ["id": .string("x")])
        XCTAssertTrue(CloudSyncService.isNewer(local, thanOrEqualTo: server))
    }

    /// Only the server side has a timestamp -> local's "" is strictly less, so the
    /// server wins.
    func testIsNewerOnlyServerHasTimestampServerWins() {
        let local = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                               fields: ["id": .string("x")])
        let server = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                                fields: ["updated_at": .string("2000-01-01 00:00:00.000")])
        XCTAssertFalse(CloudSyncService.isNewer(local, thanOrEqualTo: server))
    }

    /// Non-date timestamp strings still compare lexically (sortable-TEXT contract).
    func testIsNewerComparesNonDateStringsLexically() {
        let a = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                           fields: ["updated_at": .string("b")])
        let b = SyncRecord(id: .init(recordType: "note", recordName: "x"),
                           fields: ["updated_at": .string("a")])
        XCTAssertTrue(CloudSyncService.isNewer(a, thanOrEqualTo: b))
        XCTAssertFalse(CloudSyncService.isNewer(b, thanOrEqualTo: a))
    }

    // MARK: - SyncValue round trip through materialize / apply

    /// A `.data` blob and a `.null` both survive apply -> materialize unchanged,
    /// and toggling a nullable blob column from data to null persists correctly.
    func testDataBlobAndNullRoundTripThroughApplyAndMaterialize() throws {
        let id = UUID().uuidString
        let blob = Data([0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00])

        // Apply a pulled note that carries a real RTF blob plus a genuine NULL
        // (title) column.
        let withBlob = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: [
                "id": .string(id),
                "body": .string("body text"),
                "title": .null,
                "linked_highlight_ids": .string("[]"),
                "body_rtf": .data(blob),
            ],
            changeTag: "srv-1"
        )
        try store.applyPulled(SyncPullResult(changed: [withBlob]))

        // Materialize it back and confirm the blob + null survived intact.
        let materialized = try manager.dbQueue.read { db in
            try SyncStateStore.materialize(withBlob.id, changeTag: "srv-1", in: db)
        }
        let fields = try XCTUnwrap(materialized?.fields)
        XCTAssertEqual(fields["body_rtf"], .data(blob))
        XCTAssertEqual(fields["title"], .null)
        XCTAssertEqual(fields["body"], .string("body text"))

        // Now null out the blob via a second pulled revision.
        let nulled = SyncRecord(
            id: withBlob.id,
            fields: [
                "id": .string(id),
                "body": .string("body text"),
                "linked_highlight_ids": .string("[]"),
                "body_rtf": .null,
            ],
            changeTag: "srv-2"
        )
        try store.applyPulled(SyncPullResult(changed: [nulled]))
        let after = try manager.dbQueue.read { db in
            try SyncStateStore.materialize(withBlob.id, changeTag: "srv-2", in: db)
        }
        XCTAssertEqual(after?.fields["body_rtf"], .null)
    }

    /// `.int` and `.double` columns round-trip through materialize with the right
    /// SyncValue cases (not coerced to string).
    func testIntAndDoubleMaterializeWithCorrectCases() throws {
        let id = UUID().uuidString
        try manager.dbQueue.write { db in
            try Paper(id: id, title: "T", filePath: "f.pdf",
                      freeSpaceX: 12.5, furthestPageRead: 7).insert(db)
        }
        let record = try manager.dbQueue.read { db in
            try SyncStateStore.materialize(
                SyncRecordID(recordType: "paper", recordName: id), changeTag: nil, in: db)
        }
        let fields = try XCTUnwrap(record?.fields)
        XCTAssertEqual(fields["furthest_page_read"], .int(7))
        XCTAssertEqual(fields["free_space_x"], .double(12.5))
    }

    // MARK: - Composite paper_tag apply + delete

    /// A composite-key `paper_tag` record applies (INSERT OR REPLACE on both key
    /// columns) and then deletes via the ":"-split recordName.
    func testCompositePaperTagApplyThenDelete() throws {
        let paperId = try insertPaper()
        let tagId = try insertTag(name: "ml")
        let recordName = "\(paperId):\(tagId)"

        let record = SyncRecord(
            id: SyncRecordID(recordType: "paper_tag", recordName: recordName),
            fields: ["paper_id": .string(paperId), "tag_id": .string(tagId)],
            changeTag: "srv-pt"
        )
        try store.applyPulled(SyncPullResult(changed: [record]))
        XCTAssertTrue(try rowExists("paper_tag",
                                    key: "paper_id = ? AND tag_id = ?", [paperId, tagId]))
        // Applied without being re-marked dirty (suppression).
        XCTAssertFalse(try store.pendingUploads().contains { $0.id.recordName == recordName })

        // Delete via composite tombstone id.
        try store.applyPulled(SyncPullResult(
            deleted: [SyncRecordID(recordType: "paper_tag", recordName: recordName)]))
        XCTAssertFalse(try rowExists("paper_tag",
                                     key: "paper_id = ? AND tag_id = ?", [paperId, tagId]))
    }

    // MARK: - Delete ordering (children before parents)

    /// A single pull deleting a paper together with its highlight and comment
    /// succeeds regardless of listing order: deletions apply child-first, so no
    /// dangling reference or missing-row error occurs, and all sync_state and FTS
    /// bookkeeping is cleared.
    func testDeleteOrderingRemovesParentAndChildrenTogether() throws {
        let paperId = try insertPaper()
        let highlightId = UUID().uuidString
        let commentId = UUID().uuidString
        try manager.dbQueue.write { db in
            try Highlight(id: highlightId, paperId: paperId, page: 0,
                          boundingBoxes: "[]", selectedText: "sel").insert(db)
            let comment = Comment(id: commentId, highlightId: highlightId,
                                  paperId: paperId, body: "note")
            try comment.insert(db)
            try SearchIndex.indexComment(comment, in: db)
        }

        // Deliberately list parent FIRST to prove ordering is handled internally.
        try store.applyPulled(SyncPullResult(deleted: [
            SyncRecordID(recordType: "paper", recordName: paperId),
            SyncRecordID(recordType: "highlight", recordName: highlightId),
            SyncRecordID(recordType: "comment", recordName: commentId),
        ]))

        XCTAssertFalse(try rowExists("paper", key: "id = ?", [paperId]))
        XCTAssertFalse(try rowExists("highlight", key: "id = ?", [highlightId]))
        XCTAssertFalse(try rowExists("comment", key: "id = ?", [commentId]))
        // Comment FTS row cleared, and no tombstones/state linger for any of them.
        let residualIndex = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?",
                             arguments: [commentId]) ?? -1
        }
        XCTAssertEqual(residualIndex, 0)
        let residualState = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state WHERE entity_id IN (?, ?, ?)",
                             arguments: [paperId, highlightId, commentId]) ?? -1
        }
        XCTAssertEqual(residualState, 0)
    }

    /// Upsert of a parent and its child in the SAME pull: parents apply before
    /// children so the child's FK is satisfiable when FK enforcement is on.
    func testUpsertParentBeforeChildInOnePull() throws {
        let paperId = UUID().uuidString
        let highlightId = UUID().uuidString
        // Intentionally list child (highlight) BEFORE parent (paper) in the array;
        // apply must still order by entity type (paper before highlight).
        let child = SyncRecord(
            id: SyncRecordID(recordType: "highlight", recordName: highlightId),
            fields: ["id": .string(highlightId), "paper_id": .string(paperId),
                     "page": .int(1), "bounding_boxes": .string("[]"),
                     "selected_text": .string("s"), "color": .string("yellow")],
            changeTag: "h")
        let parent = SyncRecord(
            id: SyncRecordID(recordType: "paper", recordName: paperId),
            fields: ["id": .string(paperId), "file_path": .string("f.pdf"),
                     "reading_status": .string("unread"), "furthest_page_read": .int(0)],
            changeTag: "p")
        try store.applyPulled(SyncPullResult(changed: [child, parent]))
        XCTAssertTrue(try rowExists("paper", key: "id = ?", [paperId]))
        XCTAssertTrue(try rowExists("highlight", key: "id = ?", [highlightId]))
    }

    // MARK: - Token paging via moreComing

    /// `pull()` follows `moreComing`, applying every page, summing the applied
    /// counts, and landing on the final page's token.
    func testMultiPagePullFollowsMoreComing() async throws {
        let id1 = UUID().uuidString
        let id2 = UUID().uuidString
        let token1 = SyncChangeToken(data: Data([1]))
        let token2 = SyncChangeToken(data: Data([2]))

        func noteRecord(_ id: String, _ body: String) -> SyncRecord {
            SyncRecord(id: SyncRecordID(recordType: "note", recordName: id),
                       fields: ["id": .string(id), "body": .string(body),
                                "linked_highlight_ids": .string("[]")],
                       changeTag: "srv")
        }

        let backend = PagingFakeBackend()
        await backend.setPullResults([
            SyncPullResult(changed: [noteRecord(id1, "page1")], newToken: token1, moreComing: true),
            SyncPullResult(changed: [noteRecord(id2, "page2")], newToken: token2, moreComing: false),
        ])
        let service = CloudSyncService(store: store, backend: backend)

        let applied = try await service.pull()

        XCTAssertEqual(applied, 2)
        XCTAssertEqual(try store.changeToken(), token2)
        XCTAssertTrue(try rowExists("note", key: "id = ?", [id1]))
        XCTAssertTrue(try rowExists("note", key: "id = ?", [id2]))
        let calls = await backend.fetchCallCount
        XCTAssertEqual(calls, 2)
    }

    /// An empty change set is a clean no-op: zero applied, token preserved.
    func testEmptyPullIsNoOp() async throws {
        let existing = SyncChangeToken(data: Data([7, 7]))
        try setStoredToken(existing)
        let backend = PagingFakeBackend()
        await backend.setPullResults([SyncPullResult(newToken: existing, moreComing: false)])
        let service = CloudSyncService(store: store, backend: backend)

        let applied = try await service.pull()
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(try store.changeToken(), existing)
    }

    // MARK: - Suppression correctness

    /// After a normal applyPulled the suppress flag is reset to 0 and subsequent
    /// local writes are tracked (dirtied) again.
    func testSuppressResetToZeroAfterApply() throws {
        XCTAssertEqual(try suppressFlag(), 0)
        let id = UUID().uuidString
        let record = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: ["id": .string(id), "body": .string("b"),
                     "linked_highlight_ids": .string("[]")],
            changeTag: "srv")
        try store.applyPulled(SyncPullResult(changed: [record]))
        XCTAssertEqual(try suppressFlag(), 0)

        // Tracking works again: a later local edit re-dirties.
        try manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE note SET body = 'edited' WHERE id = ?", arguments: [id])
        }
        XCTAssertTrue(try store.pendingUploads().contains { $0.id.recordName == id })
    }

    /// If an applyPulled transaction throws mid-flight (NOT NULL violation on one
    /// record), the whole write rolls back INCLUDING the suppress flag, so
    /// suppression is not left stuck on. A following local write is still tracked.
    func testSuppressRolledBackWhenApplyThrows() throws {
        // Missing the NOT NULL `body` column -> INSERT fails inside applyPulled.
        let bad = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: UUID().uuidString),
            fields: ["id": .string(UUID().uuidString)],  // no body
            changeTag: "srv")
        XCTAssertThrowsError(try store.applyPulled(SyncPullResult(changed: [bad])))

        // Suppress must be back at 0 (rolled back with the transaction).
        XCTAssertEqual(try suppressFlag(), 0)

        // And tracking is healthy: a fresh local note is dirtied.
        let notes = NoteRepository(database: manager)
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "t")
        XCTAssertTrue(try store.pendingUploads().contains { $0.id.recordName == note.id })
    }

    /// A pulled record does not linger as a pending upload, and its server change
    /// tag is recorded on the sync_state row.
    func testPulledRecordIsNotDirtyAndStoresChangeTag() throws {
        let id = UUID().uuidString
        let record = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: ["id": .string(id), "body": .string("b"),
                     "linked_highlight_ids": .string("[]")],
            changeTag: "srv-tag-9")
        try store.applyPulled(SyncPullResult(changed: [record]))

        XCTAssertFalse(try store.pendingUploads().contains { $0.id.recordName == id })
        let tag = try manager.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT ck_change_tag FROM sync_state WHERE entity_id = ?",
                                arguments: [id])
        }
        XCTAssertEqual(tag, "srv-tag-9")
    }
}

/// A fake backend that replays scripted pull pages and counts fetch calls, for
/// exercising `CloudSyncService`'s `moreComing` paging loop.
private actor PagingFakeBackend: CloudKitBackend {
    private var pullResults: [SyncPullResult] = []
    private var index = 0
    private(set) var fetchCallCount = 0

    func setPullResults(_ results: [SyncPullResult]) { pullResults = results }

    func ensureZone() async throws {}

    func save(records: [SyncRecord], deletions: [SyncRecordID]) async throws -> SyncPushResult {
        var tags: [SyncRecordID: String] = [:]
        for record in records { tags[record.id] = "srv" }
        return SyncPushResult(savedChangeTags: tags, conflicts: [])
    }

    func fetchChanges(since token: SyncChangeToken?) async throws -> SyncPullResult {
        fetchCallCount += 1
        guard index < pullResults.count else {
            return SyncPullResult(newToken: token, moreComing: false)
        }
        defer { index += 1 }
        return pullResults[index]
    }
}
