import Foundation
import GRDB

/// Adds `paper.free_space_x` + `paper.free_space_y` for the free-space canvas
/// placement feature (Session 12). Both are nullable — null means the paper
/// hasn't been placed on the canvas yet. Additive migration — never edit
/// V1/V2/V3; new schema changes get a new migration.
enum V4AddFreeSpacePosition {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4_add_free_space_position") { db in
            try db.alter(table: "paper") { t in
                t.add(column: "free_space_x", .double)
                t.add(column: "free_space_y", .double)
            }
        }
    }
}
