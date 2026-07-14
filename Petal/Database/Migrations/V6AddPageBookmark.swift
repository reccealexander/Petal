import Foundation
import GRDB

/// Adds per-page reader bookmarks. Deleting the parent paper cascades its
/// bookmarks through the foreign key.
enum V6AddPageBookmark {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_add_page_bookmark") { db in
            try db.create(table: "page_bookmark") { t in
                t.primaryKey("id", .text)
                t.column("paper_id", .text).references("paper", onDelete: .cascade)
                t.column("page", .integer).notNull()
            }
        }
    }
}
