import Foundation
import GRDB

/// Tracks the greatest 1-based page count reached for thumbnail progress.
enum V8AddFurthestPageRead {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_add_furthest_page_read") { db in
            try db.alter(table: "paper") { t in
                t.add(column: "furthest_page_read", .integer).defaults(to: 0)
            }
        }
    }
}
