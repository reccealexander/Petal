import Foundation
import GRDB

/// Reads and writes the `sync_state` / `sync_cursor` / `sync_control` bookkeeping
/// tables and translates rows to/from provider-neutral `SyncRecord`s. All row
/// mapping is **generic** (driven by `SyncedEntity.all` + GRDB `Row`), so no
/// per-model code is needed and a new synced table only needs a registry entry
/// plus a trigger migration.
public final class SyncStateStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    // MARK: - Pending local changes (push side)

    /// Materialized records for every dirty, non-deleted row.
    public func pendingUploads() throws -> [SyncRecord] {
        try dbQueue.read { db in
            let rows = try SyncStateRow.fetchAll(
                db,
                sql: "SELECT * FROM sync_state WHERE dirty = 1 AND deleted = 0"
            )
            return try rows.compactMap { try Self.materialize($0.recordID, changeTag: $0.ckChangeTag, in: db) }
        }
    }

    /// Ids of every dirty tombstone (locally deleted, awaiting server delete).
    public func pendingDeletions() throws -> [SyncRecordID] {
        try dbQueue.read { db in
            try SyncStateRow
                .fetchAll(db, sql: "SELECT * FROM sync_state WHERE dirty = 1 AND deleted = 1")
                .map(\.recordID)
        }
    }

    /// After a successful push: clear the dirty flag and store the server change
    /// tag for saved rows, and drop tombstone rows entirely for confirmed deletes.
    public func markUploaded(saved: [SyncRecordID: String], deleted: [SyncRecordID]) throws {
        try dbQueue.write { db in
            for (id, tag) in saved {
                try db.execute(
                    sql: """
                    UPDATE sync_state SET dirty = 0, ck_change_tag = ?
                    WHERE entity_type = ? AND entity_id = ?
                    """,
                    arguments: [tag, id.recordType, id.recordName]
                )
            }
            for id in deleted {
                try db.execute(
                    sql: "DELETE FROM sync_state WHERE entity_type = ? AND entity_id = ?",
                    arguments: [id.recordType, id.recordName]
                )
            }
        }
    }

    // MARK: - Applying server changes (pull side)

    /// Applies pulled changes and deletions inside one transaction with tracking
    /// **suppressed**, so the writes don't re-mark the rows dirty. Updates each
    /// applied row's change tag, refreshes affected `search_index` entries, and
    /// advances the stored server change token.
    /// - Parameter force: when true, applies records even over a dirty local
    ///   row (used by push conflict resolution once last-writer-wins has decided
    ///   the server record wins). When false (a normal pull), dirty local rows
    ///   are left untouched so unpushed edits aren't clobbered.
    public func applyPulled(_ result: SyncPullResult, force: Bool = false) throws {
        try dbQueue.write { db in
            try Self.setSuppress(true, in: db)
            defer { try? Self.setSuppress(false, in: db) }

            // Apply upserts parent-first, deletions child-first (reverse).
            let order = SyncedEntity.all.map(\.entityType)
            let changedByType = Dictionary(grouping: result.changed) { $0.id.recordType }
            for type in order {
                for record in changedByType[type] ?? [] {
                    try Self.apply(record, force: force, in: db)
                }
            }
            let deletedByType = Dictionary(grouping: result.deleted) { $0.recordType }
            for type in order.reversed() {
                for id in deletedByType[type] ?? [] {
                    try Self.applyDeletion(id, in: db)
                }
            }

            if let token = result.newToken {
                try db.execute(
                    sql: "UPDATE sync_cursor SET server_change_token = ? WHERE id = 0",
                    arguments: [token.data]
                )
            }
        }
    }

    // MARK: - Cursor / zone state

    public func changeToken() throws -> SyncChangeToken? {
        try dbQueue.read { db in
            guard let data = try Data.fetchOne(
                db, sql: "SELECT server_change_token FROM sync_cursor WHERE id = 0"
            ) else { return nil }
            return SyncChangeToken(data: data)
        }
    }

    public func zoneCreated() throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT zone_created FROM sync_cursor WHERE id = 0") ?? false
        }
    }

    public func setZoneCreated(_ created: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_cursor SET zone_created = ? WHERE id = 0",
                arguments: [created]
            )
        }
    }

    // MARK: - Generic row <-> record mapping

    /// Reads one row and packages all its columns as a `SyncRecord`. Returns nil
    /// if the row no longer exists (e.g. deleted between selection and read).
    static func materialize(_ id: SyncRecordID, changeTag: String?, in db: Database) throws -> SyncRecord? {
        guard let entity = SyncedEntity.lookup(id.recordType) else { return nil }
        let whereClause = entity.keyColumns.map { "\"\($0)\" = ?" }.joined(separator: " AND ")
        let keyValues = entity.keyValues(fromRecordName: id.recordName)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \"\(entity.table)\" WHERE \(whereClause)",
            arguments: StatementArguments(keyValues)
        ) else { return nil }

        var fields: [String: SyncValue] = [:]
        for (column, dbValue) in row {
            fields[column] = SyncValue(databaseValue: dbValue)
        }
        return SyncRecord(id: id, fields: fields, changeTag: changeTag)
    }

    /// Upserts a pulled record into its table and records its change tag /
    /// refreshes FTS. Must run under suppressed tracking.
    ///
    /// Uses a true `ON CONFLICT(pk) DO UPDATE` upsert, NOT `INSERT OR REPLACE`:
    /// the latter resolves a PK conflict by DELETE-then-INSERT, which fires
    /// `ON DELETE CASCADE` and would wipe the row's children (highlights,
    /// comments, notes, tags…) on every pulled parent update — silent data loss.
    /// The upsert updates the existing row in place, so no cascade occurs.
    ///
    /// If the local row is DIRTY (an unpushed local edit), the pulled record is
    /// skipped so the edit isn't clobbered; the next push surfaces the conflict
    /// and last-writer-wins resolves it there.
    static func apply(_ record: SyncRecord, force: Bool = false, in db: Database) throws {
        guard let entity = SyncedEntity.lookup(record.id.recordType) else { return }
        let columns = Array(record.fields.keys)
        guard !columns.isEmpty else { return }

        if !force {
            let isDirty = (try Bool.fetchOne(
                db,
                sql: "SELECT dirty FROM sync_state WHERE entity_type = ? AND entity_id = ?",
                arguments: [record.id.recordType, record.id.recordName]
            )) ?? false
            if isDirty { return }
        }

        let quotedCols = columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let keyCols = entity.keyColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let updates = columns.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
        let values = columns.map { record.fields[$0]!.databaseValue }
        try db.execute(
            sql: """
            INSERT INTO "\(entity.table)" (\(quotedCols)) VALUES (\(placeholders))
            ON CONFLICT(\(keyCols)) DO UPDATE SET \(updates)
            """,
            arguments: StatementArguments(values)
        )

        try refreshSearchIndex(entity: entity, record: record, in: db)

        try db.execute(
            sql: """
            INSERT INTO sync_state (entity_type, entity_id, dirty, deleted, ck_change_tag, local_updated_at)
            VALUES (?, ?, 0, 0, ?, strftime('%Y-%m-%d %H:%M:%f','now'))
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                dirty = 0, deleted = 0, ck_change_tag = excluded.ck_change_tag;
            """,
            arguments: [record.id.recordType, record.id.recordName, record.changeTag]
        )
    }

    /// Deletes a pulled tombstone's row (FTS entry too) and its sync_state.
    static func applyDeletion(_ id: SyncRecordID, in db: Database) throws {
        guard let entity = SyncedEntity.lookup(id.recordType) else { return }
        let whereClause = entity.keyColumns.map { "\"\($0)\" = ?" }.joined(separator: " AND ")
        let keyValues = entity.keyValues(fromRecordName: id.recordName)
        try db.execute(
            sql: "DELETE FROM \"\(entity.table)\" WHERE \(whereClause)",
            arguments: StatementArguments(keyValues)
        )
        if entity.searchType != nil {
            try SearchIndex.remove(entityId: id.recordName, in: db)
        }
        try db.execute(
            sql: "DELETE FROM sync_state WHERE entity_type = ? AND entity_id = ?",
            arguments: [id.recordType, id.recordName]
        )
    }

    /// Rebuilds the `search_index` row for a pulled paper/note/comment from the
    /// freshly-applied row (FTS is derived and never synced, per the schema's
    /// no-triggers/no-FK invariant).
    private static func refreshSearchIndex(entity: SyncedEntity, record: SyncRecord, in db: Database) throws {
        guard let searchType = entity.searchType else { return }
        switch searchType {
        case .paper:
            if let paper = try Paper.fetchOne(db, key: record.id.recordName) {
                try SearchIndex.indexPaper(paper, in: db)
            }
        case .note:
            if let note = try Note.fetchOne(db, key: record.id.recordName) {
                try SearchIndex.indexNote(note, in: db)
            }
        case .comment:
            if let comment = try Comment.fetchOne(db, key: record.id.recordName) {
                try SearchIndex.indexComment(comment, in: db)
            }
        }
    }

    // MARK: - Suppression

    private static func setSuppress(_ on: Bool, in db: Database) throws {
        try db.execute(sql: "UPDATE sync_control SET suppress = ? WHERE id = 0", arguments: [on])
    }
}
