import XCTest
import GRDB
@testable import PetalCore

/// Adversarial edge-case / error-path coverage for the persistence core:
/// foreign-key cascade vs. FTS-row cleanup, V11 auto-tracking triggers,
/// pull-apply suppression, composite `paper_tag` keys, recursive notebook
/// traversal + cycle safety, and the applied-migration list.
///
/// Every test here is intended to be GREEN against current code — it documents
/// and pins behavior that already holds. (Known bugs are reported separately and
/// deliberately NOT encoded as failing tests here.)
final class PersistenceEdgeCaseTests: XCTestCase {
    private var manager: DatabaseManager!
    private var dbQueue: DatabaseQueue { manager.dbQueue }
    private var store: SyncStateStore!
    private var highlights: HighlightRepository!
    private var notes: NoteRepository!
    private var notebooks: NotebookRepository!
    private var tags: TagRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager.inMemory()
        store = SyncStateStore(database: manager)
        highlights = HighlightRepository(database: manager)
        notes = NoteRepository(database: manager)
        notebooks = NotebookRepository(database: manager)
        tags = TagRepository(database: manager)
    }

    override func tearDownWithError() throws {
        manager = nil
    }

    // MARK: - Helpers

    private func ftsCount(entityId: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM search_index WHERE entity_id = ?", arguments: [entityId]
            ) ?? -1
        }
    }

    private func syncRow(type: String, id: String) throws -> Row? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT dirty, deleted FROM sync_state WHERE entity_type = ? AND entity_id = ?",
                arguments: [type, id]
            )
        }
    }

    // MARK: - Migration list & FK enablement

    func testAppliedMigrationsListMatchesRegisteredMigratorInOrder() throws {
        let applied = try manager.appliedMigrations()
        XCTAssertEqual(applied, [
            "v1_initial_schema",
            "v2_add_file_hash",
            "v3_add_notebook_summary",
            "v4_add_free_space_position",
            "v5_add_pinned_at",
            "v6_add_page_bookmark",
            "v7_add_reading_progress",
            "v8_add_furthest_page_read",
            "v9_add_note_rtf",
            "v10_add_notebook_summary_paper_set",
            "v11_add_sync_state",
        ])
    }

    /// Re-running the migrator against an already-migrated database is a no-op
    /// (idempotent) and does not duplicate the applied-migration list.
    func testMigratorIsIdempotentOnAlreadyMigratedDatabase() throws {
        try DatabaseManager.migrator.migrate(dbQueue)
        try DatabaseManager.migrator.migrate(dbQueue)
        XCTAssertEqual(try manager.appliedMigrations().count, 11)

        // The single-row control tables were seeded exactly once, not per re-run.
        let cursorCount = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_cursor") }
        let controlCount = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_control") }
        XCTAssertEqual(cursorCount, 1)
        XCTAssertEqual(controlCount, 1)
    }

    // MARK: - FK cascade + FTS-row cleanup (paper delete)

    /// Deleting a paper through the repository cascades highlights/comments/notes
    /// AND removes every derived `search_index` row (paper, its comments, its
    /// notes) — FTS has no triggers/FKs, so the repository is the safety net.
    func testDeletePaperRemovesCascadedRowsAndAllTheirFTSEntries() throws {
        let paper = Paper(title: "Attention Is All You Need", filePath: "cascade.pdf")
        let hl = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "sel")
        let comment = Comment(highlightId: hl.id, paperId: paper.id, body: "great point about attention")
        try dbQueue.write { db in
            try paper.insert(db)
            try hl.insert(db)
            try comment.insert(db)
            try SearchIndex.indexPaper(paper, in: db)
            try SearchIndex.indexComment(comment, in: db)
        }
        let note = try notes.loadOrCreatePrimaryNote(forPaper: paper.id, title: "n")
        try notes.save(Note(id: note.id, paperId: paper.id, notebookId: nil, title: "n",
                            body: "transformer notes", linkedHighlightIds: "[]"))

        // Precondition: all four FTS rows exist.
        XCTAssertEqual(try ftsCount(entityId: paper.id), 1)
        XCTAssertEqual(try ftsCount(entityId: comment.id), 1)
        XCTAssertEqual(try ftsCount(entityId: note.id), 1)

        let removed = try notebooks.deletePapers(ids: [paper.id])
        XCTAssertEqual(removed.map(\.id), [paper.id])

        // Data rows are gone (FK cascade)...
        try dbQueue.read { db in
            XCTAssertEqual(try Highlight.fetchCount(db), 0)
            XCTAssertEqual(try Comment.fetchCount(db), 0)
            XCTAssertEqual(try Note.fetchCount(db), 0)
        }
        // ...and so are ALL of their FTS rows (no leaks).
        XCTAssertEqual(try ftsCount(entityId: paper.id), 0)
        XCTAssertEqual(try ftsCount(entityId: comment.id), 0)
        XCTAssertEqual(try ftsCount(entityId: note.id), 0)
    }

    /// Deleting a highlight cascades its comment away and the repository removes
    /// the comment's FTS row in the same transaction.
    func testDeleteHighlightRemovesItsCommentFTSRow() throws {
        let paper = Paper(filePath: "h.pdf")
        let hl = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "s")
        try dbQueue.write { db in
            try paper.insert(db)
            try hl.insert(db)
        }
        let comment = try highlights.upsertComment(highlightId: hl.id, paperId: paper.id, body: "comment body")
        XCTAssertEqual(try ftsCount(entityId: comment.id), 1)

        try highlights.deleteHighlight(id: hl.id)

        try dbQueue.read { db in XCTAssertEqual(try Comment.fetchCount(db), 0) }
        XCTAssertEqual(try ftsCount(entityId: comment.id), 0, "cascaded comment's FTS row must not leak")
    }

    // MARK: - V11 auto-tracking triggers: dirty / tombstone

    func testInsertAndUpdateMarkRowDirtyNotDeleted() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "x")
        let afterInsert = try XCTUnwrap(syncRow(type: "note", id: note.id))
        XCTAssertEqual(afterInsert["dirty"] as Int, 1)
        XCTAssertEqual(afterInsert["deleted"] as Int, 0)

        // Mark clean, then a raw UPDATE must re-dirty it via the AFTER UPDATE trigger.
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_state SET dirty = 0 WHERE entity_type = 'note' AND entity_id = ?",
                           arguments: [note.id])
            try db.execute(sql: "UPDATE note SET body = 'edited' WHERE id = ?", arguments: [note.id])
        }
        let afterUpdate = try XCTUnwrap(syncRow(type: "note", id: note.id))
        XCTAssertEqual(afterUpdate["dirty"] as Int, 1)
        XCTAssertEqual(afterUpdate["deleted"] as Int, 0)
    }

    func testDeleteCreatesDirtyTombstone() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "doomed")
        try notes.deleteNote(id: note.id)
        let row = try XCTUnwrap(syncRow(type: "note", id: note.id))
        XCTAssertEqual(row["dirty"] as Int, 1)
        XCTAssertEqual(row["deleted"] as Int, 1)
    }

    /// A cascade delete (paper -> highlight -> comment) fires the AFTER DELETE
    /// triggers on the cascaded child rows too, so every cascaded row gets its
    /// own tombstone — the sync layer relies on this to propagate the deletions.
    func testCascadeDeleteTombstonesEveryCascadedChild() throws {
        let paper = Paper(filePath: "casc.pdf")
        let hl = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "s")
        let comment = Comment(highlightId: hl.id, paperId: paper.id, body: "c")
        try dbQueue.write { db in
            try paper.insert(db); try hl.insert(db); try comment.insert(db)
            // Start from a clean slate so we only observe delete-driven tombstones.
            try db.execute(sql: "DELETE FROM sync_state")
            try db.execute(sql: "DELETE FROM paper WHERE id = ?", arguments: [paper.id])
        }
        for (type, id) in [("paper", paper.id), ("highlight", hl.id), ("comment", comment.id)] {
            let row = try XCTUnwrap(syncRow(type: type, id: id), "missing tombstone for \(type)")
            XCTAssertEqual(row["deleted"] as Int, 1, "\(type) should be a tombstone")
            XCTAssertEqual(row["dirty"] as Int, 1, "\(type) tombstone should be dirty")
        }
    }

    // MARK: - Suppression during pull-apply

    /// Applying a pulled INSERT/UPDATE under suppression must NOT re-mark the row
    /// dirty, and must leave the suppress flag back OFF afterwards so subsequent
    /// local writes are tracked again.
    func testApplyPulledDoesNotReDirtyAndRestoresSuppressFlag() throws {
        let id = UUID().uuidString
        let record = SyncRecord(
            id: SyncRecordID(recordType: "note", recordName: id),
            fields: ["id": .string(id), "body": .string("pulled"), "linked_highlight_ids": .string("[]")],
            changeTag: "srv-1"
        )
        try store.applyPulled(SyncPullResult(changed: [record]))

        // Row is present, clean (dirty=0), and NOT queued for upload.
        let row = try XCTUnwrap(syncRow(type: "note", id: id))
        XCTAssertEqual(row["dirty"] as Int, 0)
        XCTAssertFalse(try store.pendingUploads().contains { $0.id.recordName == id })

        // Suppress flag was restored to 0: a subsequent local write re-dirties.
        let suppress = try dbQueue.read { try Int.fetchOne($0, sql: "SELECT suppress FROM sync_control WHERE id = 0") }
        XCTAssertEqual(suppress, 0)

        try dbQueue.write { db in
            try db.execute(sql: "UPDATE note SET body = 'local edit' WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(try XCTUnwrap(syncRow(type: "note", id: id))["dirty"] as Int, 1)
    }

    func testApplyPulledDeletionRemovesRowAndFTS() throws {
        let note = try notes.createNote(paperId: nil, notebookId: nil, title: "bye")
        XCTAssertEqual(try ftsCount(entityId: note.id), 1)
        try store.applyPulled(SyncPullResult(deleted: [SyncRecordID(recordType: "note", recordName: note.id)]))
        XCTAssertNil(try notes.note(id: note.id))
        XCTAssertEqual(try ftsCount(entityId: note.id), 0)
    }

    // MARK: - Composite paper_tag key round-trip

    /// The AFTER INSERT trigger builds the composite `entity_id` as
    /// `paper_id:tag_id`, and `SyncedEntity.keyValues` splits it back apart —
    /// the two must agree so `materialize` can re-fetch the row.
    func testCompositePaperTagKeyIsBuiltAndSplitConsistently() throws {
        let paper = Paper(filePath: "t.pdf")
        try dbQueue.write { try paper.insert($0) }
        let tag = try tags.addTag(name: "physics", toPaper: paper.id)
        let expectedEntityId = "\(paper.id):\(tag.id)"

        // Trigger recorded the composite key.
        let row = try XCTUnwrap(syncRow(type: "paper_tag", id: expectedEntityId))
        XCTAssertEqual(row["dirty"] as Int, 1)

        // keyValues splits it back into [paper_id, tag_id].
        let entity = try XCTUnwrap(SyncedEntity.lookup("paper_tag"))
        XCTAssertEqual(entity.keyValues(fromRecordName: expectedEntityId), [paper.id, tag.id])

        // And the composite row materializes end-to-end (proves the split feeds a
        // valid WHERE clause that finds the row).
        let uploads = try store.pendingUploads()
        let materialized = try XCTUnwrap(uploads.first { $0.id.recordName == expectedEntityId })
        XCTAssertEqual(materialized.id.recordType, "paper_tag")
        XCTAssertEqual(materialized.fields["paper_id"], .string(paper.id))
        XCTAssertEqual(materialized.fields["tag_id"], .string(tag.id))
    }

    /// Deleting a paper cascades its `paper_tag` join row and tombstones it under
    /// the same composite key (so the association deletion can be synced).
    func testDeletingPaperTombstonesCompositePaperTagRow() throws {
        let paper = Paper(filePath: "t2.pdf")
        try dbQueue.write { try paper.insert($0) }
        let tag = try tags.addTag(name: "ml", toPaper: paper.id)
        let compositeId = "\(paper.id):\(tag.id)"

        _ = try notebooks.deletePapers(ids: [paper.id])

        let row = try XCTUnwrap(syncRow(type: "paper_tag", id: compositeId))
        XCTAssertEqual(row["deleted"] as Int, 1)
        // The tag itself survives (only the association was removed).
        XCTAssertEqual(try tags.allTags().map(\.id), [tag.id])
    }

    // MARK: - Recursive notebook CTE + cycle safety

    /// Deep acyclic tree: the recursive CTE gathers papers from every descendant
    /// level and excludes siblings outside the subtree.
    func testRecursiveTraversalGathersDeepDescendantsOnly() throws {
        let a = try notebooks.create(name: "A", parentId: nil)
        let b = try notebooks.create(name: "B", parentId: a.id)
        let c = try notebooks.create(name: "C", parentId: b.id)
        let d = try notebooks.create(name: "D", parentId: c.id)
        let other = try notebooks.create(name: "Other", parentId: nil)

        let deep = Paper(notebookId: d.id, filePath: "deep.pdf")
        let mid = Paper(notebookId: b.id, filePath: "mid.pdf")
        let outside = Paper(notebookId: other.id, filePath: "out.pdf")
        try dbQueue.write { db in
            try deep.insert(db); try mid.insert(db); try outside.insert(db)
        }

        let underA = Set(try notebooks.papersUnder(notebookId: a.id).map(\.id))
        XCTAssertEqual(underA, [deep.id, mid.id])
        XCTAssertTrue(try notebooks.containsPapers(notebookId: a.id))
        // The leaf `d` contains one paper; the empty sibling subtree contains none.
        XCTAssertTrue(try notebooks.containsPapers(notebookId: d.id))
        XCTAssertFalse(try notebooks.containsPapers(notebookId: c.id) == false, "c has descendant paper via d")
        XCTAssertTrue(try notebooks.containsPapers(notebookId: other.id))
    }

    /// The `move` guard is the cycle-safety net for the recursive CTE: it refuses
    /// to re-parent a notebook under itself or any descendant, which is the only
    /// thing preventing the `UNION ALL` traversal from being handed a cyclic
    /// graph (a genuine cycle would make it non-terminating). This pins that the
    /// guard fires for both the self-parent and descendant-parent cases.
    func testMoveRefusesToCreateNotebookCycle() throws {
        let root = try notebooks.create(name: "root", parentId: nil)
        let child = try notebooks.create(name: "child", parentId: root.id)
        let grandchild = try notebooks.create(name: "grandchild", parentId: child.id)

        // Self-parenting is refused.
        XCTAssertThrowsError(try notebooks.move(id: root.id, toParent: root.id)) {
            XCTAssertEqual($0 as? NotebookError, .wouldCreateCycle)
        }
        // Parenting an ancestor under its own descendant is refused.
        XCTAssertThrowsError(try notebooks.move(id: root.id, toParent: grandchild.id)) {
            XCTAssertEqual($0 as? NotebookError, .wouldCreateCycle)
        }

        // A legal move still works and the tree stays traversable (terminating).
        let sibling = try notebooks.create(name: "sibling", parentId: nil)
        XCTAssertNoThrow(try notebooks.move(id: sibling.id, toParent: grandchild.id))
        let underRoot = try notebooks.papersUnder(notebookId: root.id) // must terminate
        XCTAssertEqual(underRoot.count, 0)
    }

    // MARK: - Search consistency after deletes

    /// After deleting the paper, a full-text search for its unique content term
    /// returns no stale hits (the derived index tracked the delete).
    func testSearchReturnsNoStaleHitsAfterPaperDeleted() throws {
        let search = SearchRepository(database: manager)
        let paper = Paper(filePath: "s.pdf")
        let hl = Highlight(paperId: paper.id, page: 0, boundingBoxes: "[]", selectedText: "s")
        try dbQueue.write { db in
            try paper.insert(db); try hl.insert(db)
        }
        _ = try highlights.upsertComment(highlightId: hl.id, paperId: paper.id, body: "zygomorphic terminology")

        XCTAssertEqual(try search.search("zygomorphic").count, 1)

        _ = try notebooks.deletePapers(ids: [paper.id])
        XCTAssertTrue(try search.search("zygomorphic").isEmpty, "deleted comment must not remain searchable")
    }
}
