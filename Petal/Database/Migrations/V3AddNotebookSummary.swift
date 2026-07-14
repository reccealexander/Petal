import Foundation
import GRDB

/// Adds `notebook.ai_summary` + `notebook.ai_summary_note_count` for the
/// AI-generated notebook summary feature (Session 10). Additive migration —
/// never edit V1/V2; new schema changes get a new migration.
enum V3AddNotebookSummary {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_add_notebook_summary") { db in
            try db.alter(table: "notebook") { t in
                t.add(column: "ai_summary", .text)
                t.add(column: "ai_summary_note_count", .integer).defaults(to: 0)
            }
        }
    }
}
