import Foundation
import GRDB

/// Adds `paper.file_hash` for import dedupe (spec §3 Phase 1). Additive migration —
/// never edit V1; new schema changes get a new migration.
enum V2AddFileHash {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_add_file_hash") { db in
            try db.alter(table: "paper") { t in
                t.add(column: "file_hash", .text)
            }
            try db.create(index: "index_paper_on_file_hash", on: "paper", columns: ["file_hash"])
        }
    }
}
