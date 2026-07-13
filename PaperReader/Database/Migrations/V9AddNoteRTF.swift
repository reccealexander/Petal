import Foundation
import GRDB

/// Adds the canonical rich-text representation of notes. AppKit is deliberately
/// avoided here so the core database target stays UI-framework independent.
enum V9AddNoteRTF {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9_add_note_rtf") { db in
            try db.alter(table: "note") { table in
                table.add(column: "body_rtf", .blob)
            }

            let notes = try Row.fetchAll(db, sql: "SELECT id, body FROM note")
            for note in notes {
                let id: String = note["id"]
                let body: String = note["body"]
                try db.execute(
                    sql: "UPDATE note SET body_rtf = ? WHERE id = ?",
                    arguments: [minimalRTF(for: body), id]
                )
            }
        }
    }

    private static func minimalRTF(for text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\par ")
        return Data("{\\rtf1\\ansi\\ansicpg1252 \(escaped) }".utf8)
    }
}
