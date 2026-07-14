import Foundation
import GRDB

/// Tracks the exact paper set used for a notebook's cached AI summary.
/// The legacy note-count column remains in place for migration compatibility.
enum V10AddNotebookSummaryPaperSet {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10_add_notebook_summary_paper_set") { db in
            try db.alter(table: "notebook") { table in
                table.add(column: "ai_summary_paper_ids_hash", .text)
                table.add(column: "ai_summary_paper_count", .integer).defaults(to: 0)
            }
        }
    }
}
