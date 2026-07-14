import Foundation
import GRDB

/// Adds the device-local bookkeeping that a later CloudKit sync layer needs,
/// without touching any existing data table (purely additive).
///
/// - `sync_state`: one row per synced entity recording whether it has local
///   changes awaiting upload (`dirty`), whether it is a delete tombstone
///   (`deleted`), and the last-known CloudKit change tag / archived system
///   fields for correct server merges.
/// - `sync_cursor`: single row holding the per-zone `serverChangeToken` and a
///   flag for whether the CloudKit record zone has been created.
/// - `sync_control`: single row whose `suppress` flag lets the pull path apply
///   server changes *without* the tracking triggers re-marking those rows dirty
///   (which would otherwise loop the just-pulled change straight back up).
///
/// Change tracking is done with **AFTER INSERT/UPDATE/DELETE triggers** on every
/// synced table (driven by `SyncedEntity.all`) rather than by hand-annotating
/// each repository write. That makes "every write is tracked" true by
/// construction — including raw `db.execute` UPDATE/DELETE paths — and keeps the
/// repositories unchanged. FTS is still maintained explicitly by repositories;
/// these triggers are only for sync bookkeeping.
enum V11AddSyncState {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11_add_sync_state") { db in
            try db.create(table: "sync_state") { t in
                t.column("entity_type", .text).notNull()
                t.column("entity_id", .text).notNull()
                t.column("dirty", .integer).notNull().defaults(to: 1)
                t.column("deleted", .integer).notNull().defaults(to: 0)
                t.column("ck_change_tag", .text)
                t.column("ck_system_fields", .blob)
                t.column("local_updated_at", .datetime)
                t.primaryKey(["entity_type", "entity_id"])
            }
            try db.create(indexOn: "sync_state", columns: ["dirty"])

            try db.create(table: "sync_cursor") { t in
                t.column("id", .integer).primaryKey()
                t.column("server_change_token", .blob)
                t.column("zone_created", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "INSERT INTO sync_cursor (id, zone_created) VALUES (0, 0)")

            try db.create(table: "sync_control") { t in
                t.column("id", .integer).primaryKey()
                t.column("suppress", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "INSERT INTO sync_control (id, suppress) VALUES (0, 0)")

            let now = "strftime('%Y-%m-%d %H:%M:%f','now')"
            for entity in SyncedEntity.all {
                try installTriggers(for: entity, now: now, in: db)
                try backfill(entity: entity, now: now, in: db)
            }
        }
    }

    /// AFTER INSERT/UPDATE/DELETE triggers that upsert a `sync_state` row when
    /// tracking is not suppressed. Insert/update mark `dirty=1, deleted=0`;
    /// delete marks a `dirty=1, deleted=1` tombstone.
    private static func installTriggers(for entity: SyncedEntity, now: String, in db: Database) throws {
        let t = entity.table
        let type = entity.entityType
        let guardClause = "WHEN (SELECT suppress FROM sync_control WHERE id = 0) = 0"

        func upsert(key: String, deleted: Int) -> String {
            """
            INSERT INTO sync_state (entity_type, entity_id, dirty, deleted, local_updated_at)
            VALUES ('\(type)', \(key), 1, \(deleted), \(now))
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                dirty = 1, deleted = \(deleted), local_updated_at = excluded.local_updated_at;
            """
        }

        let newKey = entity.keyExpression(alias: "NEW")
        let oldKey = entity.keyExpression(alias: "OLD")

        try db.execute(sql: """
            CREATE TRIGGER "sync_\(t)_ai" AFTER INSERT ON "\(t)"
            \(guardClause)
            BEGIN
                \(upsert(key: newKey, deleted: 0))
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER "sync_\(t)_au" AFTER UPDATE ON "\(t)"
            \(guardClause)
            BEGIN
                \(upsert(key: newKey, deleted: 0))
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER "sync_\(t)_ad" AFTER DELETE ON "\(t)"
            \(guardClause)
            BEGIN
                \(upsert(key: oldKey, deleted: 1))
            END;
            """)
    }

    /// Marks every pre-existing row as needing an initial upload. Writes straight
    /// into `sync_state` (not through the data tables) so triggers are irrelevant
    /// here regardless of the suppress flag.
    private static func backfill(entity: SyncedEntity, now: String, in db: Database) throws {
        let key = entity.keyExpression(alias: entity.table)
        try db.execute(sql: """
            INSERT INTO sync_state (entity_type, entity_id, dirty, deleted, local_updated_at)
            SELECT '\(entity.entityType)', \(key), 1, 0, \(now)
            FROM "\(entity.table)"
            WHERE true
            ON CONFLICT(entity_type, entity_id) DO NOTHING;
            """)
    }
}
