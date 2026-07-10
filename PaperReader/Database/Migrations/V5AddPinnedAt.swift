import Foundation
import GRDB

/// Adds `paper.pinned_at` + `notebook.pinned_at` for the pinning feature
/// (Session 12). Both are nullable — non-nil means pinned, and the timestamp
/// can be used to order pinned items. Additive migration — never edit
/// V1/V2/V3/V4; new schema changes get a new migration.
enum V5AddPinnedAt {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_add_pinned_at") { db in
            try db.alter(table: "paper") { t in
                t.add(column: "pinned_at", .datetime)
            }
            try db.alter(table: "notebook") { t in
                t.add(column: "pinned_at", .datetime)
            }
        }
    }
}
