import Foundation
import GRDB

/// Initial schema — the full data model from spec §1.
///
/// One migration per logical change: future schema edits should register a *new*
/// migration (e.g. `V2...`) rather than editing this one, so migrations stay
/// additive and reproducible for existing installs.
enum V1InitialSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            // notebook — self-referencing tree; deleting a folder cascades to children.
            try db.create(table: "notebook") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("parent_id", .text)
                    .references("notebook", onDelete: .cascade)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("sort_order", .integer).defaults(to: 0)
            }

            // paper — deleting the containing notebook only nulls the link.
            try db.create(table: "paper") { t in
                t.primaryKey("id", .text)
                t.column("notebook_id", .text)
                    .references("notebook", onDelete: .setNull)
                t.column("title", .text)
                t.column("authors", .text)
                t.column("doi", .text)
                t.column("arxiv_id", .text)
                t.column("file_path", .text).notNull()   // relative to Papers/
                t.column("page_count", .integer)
                t.column("imported_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("last_opened_at", .datetime)
            }

            try db.create(table: "tag") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
            }

            // paper_tag — many-to-many join with a composite primary key.
            try db.create(table: "paper_tag") { t in
                t.column("paper_id", .text)
                    .notNull()
                    .references("paper", onDelete: .cascade)
                t.column("tag_id", .text)
                    .notNull()
                    .references("tag", onDelete: .cascade)
                t.primaryKey(["paper_id", "tag_id"])
            }

            try db.create(table: "highlight") { t in
                t.primaryKey("id", .text)
                t.column("paper_id", .text)
                    .references("paper", onDelete: .cascade)
                t.column("page", .integer).notNull()
                t.column("bounding_boxes", .text).notNull()   // JSON array of CGRect
                t.column("color", .text).defaults(to: "yellow")
                t.column("selected_text", .text).notNull()
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }

            // comment — cascades from both its highlight and its paper.
            try db.create(table: "comment") { t in
                t.primaryKey("id", .text)
                t.column("highlight_id", .text)
                    .references("highlight", onDelete: .cascade)
                t.column("paper_id", .text)
                    .references("paper", onDelete: .cascade)
                t.column("body", .text).notNull()             // markdown
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime)
            }

            try db.create(table: "note") { t in
                t.primaryKey("id", .text)
                t.column("paper_id", .text)
                    .references("paper", onDelete: .cascade)
                t.column("notebook_id", .text)
                    .references("notebook", onDelete: .cascade)
                t.column("title", .text)
                t.column("body", .text).notNull()             // markdown
                t.column("linked_highlight_ids", .text)       // JSON array
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime)
            }

            try db.create(table: "chat_session") { t in
                t.primaryKey("id", .text)
                t.column("scope", .text).notNull()            // 'paper' | 'notebook'
                t.column("scope_id", .text).notNull()
                t.column("messages", .text).notNull()         // JSON array
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime)
            }

            // Full-text search across searchable entities (spec §1).
            try db.create(virtualTable: "search_index", using: FTS5()) { t in
                t.column("entity_id")
                t.column("entity_type")
                t.column("paper_id")
                t.column("content")
            }
        }
    }
}
