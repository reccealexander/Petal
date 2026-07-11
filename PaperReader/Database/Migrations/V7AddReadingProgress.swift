import Foundation
import GRDB

/// Adds the persisted reader position and reading state used by Session 17.
enum V7AddReadingProgress {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7_add_reading_progress") { db in
            try db.alter(table: "paper") { t in
                t.add(column: "last_page", .integer)
                t.add(column: "last_scroll_offset", .double)
                t.add(column: "reading_status", .text).defaults(to: "unread")
            }
        }
    }
}
