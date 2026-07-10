import Foundation
import GRDB

/// Centralizes all database access for notes. The view/rendering layer must
/// never touch the DB directly — it goes through this repository instead
/// (spec §1).
public final class NoteRepository {
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    /// The paper's primary (earliest-created) note, or nil if none exists yet.
    public func primaryNote(forPaper paperId: String) throws -> Note? {
        try dbQueue.read { db in
            try Note.fetchOne(
                db,
                sql: "SELECT * FROM note WHERE paper_id = ? ORDER BY created_at LIMIT 1",
                arguments: [paperId]
            )
        }
    }

    /// Loads the paper's primary note, lazily creating an empty one if none exists.
    @discardableResult
    public func loadOrCreatePrimaryNote(forPaper paperId: String, title: String?) throws -> Note {
        if let existing = try primaryNote(forPaper: paperId) {
            return existing
        }
        var note = Note(paperId: paperId, title: title, body: "", linkedHighlightIds: "[]")
        try dbQueue.write { db in
            try note.insert(db)
            try SearchIndex.indexNote(note, in: db)
        }
        return note
    }

    /// Persists body / title / linkedHighlightIds for an existing note, stamping updated_at.
    public func save(_ note: Note) throws {
        var copy = note
        copy.updatedAt = Date()
        try dbQueue.write { db in
            try copy.update(db)
            try SearchIndex.indexNote(copy, in: db)
        }
    }

    /// Every note in the library, most-recently-updated (falling back to
    /// created) first — used by the "Notes" sidebar section (Session 7 Part A).
    public func allNotes() throws -> [Note] {
        try dbQueue.read { db in
            try Note.fetchAll(
                db,
                sql: "SELECT * FROM note ORDER BY (updated_at IS NULL), updated_at DESC, created_at DESC"
            )
        }
    }

    /// A single note by id, or nil if it doesn't exist.
    public func note(id: String) throws -> Note? {
        try dbQueue.read { db in
            try Note.fetchOne(db, key: id)
        }
    }

    /// Creates a new, empty note — optionally linked to a paper and/or a
    /// notebook, or fully unlinked (a "general" note) — and indexes it for
    /// search, mirroring `loadOrCreatePrimaryNote`'s create path.
    @discardableResult
    public func createNote(paperId: String?, notebookId: String?, title: String?) throws -> Note {
        let note = Note(paperId: paperId, notebookId: notebookId, title: title, body: "", linkedHighlightIds: "[]")
        try dbQueue.write { db in
            try note.insert(db)
            try SearchIndex.indexNote(note, in: db)
        }
        return note
    }

    /// JSON codec for the `note.linked_highlight_ids` column (array of highlight ids).
    public static func encodeLinkedIds(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    public static func decodeLinkedIds(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return ids
    }
}
