import Foundation
import GRDB

/// Centralizes all database access for tags and their assignment to papers
/// (spec §1). The view/rendering layer must never touch the DB directly — it
/// goes through this repository instead.
public final class TagRepository {
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    /// All tags, ordered by name.
    public func allTags() throws -> [Tag] {
        try dbQueue.read { db in
            try Tag.fetchAll(db, sql: "SELECT * FROM tag ORDER BY name")
        }
    }

    /// Tags assigned to a paper, ordered by name.
    public func tags(forPaper paperId: String) throws -> [Tag] {
        try dbQueue.read { db in
            try Tag.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM tag t
                    JOIN paper_tag pt ON pt.tag_id = t.id
                    WHERE pt.paper_id = ?
                    ORDER BY t.name
                    """,
                arguments: [paperId]
            )
        }
    }

    /// Create a tag, or return the existing one if a tag with that (trimmed)
    /// name already exists.
    @discardableResult
    public func createTag(name: String) throws -> Tag {
        try dbQueue.write { db in
            try TagRepository.findOrCreateTag(named: name, in: db)
        }
    }

    /// Create-or-get a tag by name and assign it to the paper. Returns the tag.
    @discardableResult
    public func addTag(name: String, toPaper paperId: String) throws -> Tag {
        try dbQueue.write { db in
            let tag = try TagRepository.findOrCreateTag(named: name, in: db)
            try PaperTag(paperId: paperId, tagId: tag.id).insert(db, onConflict: .ignore)
            return tag
        }
    }

    /// Assign an existing tag to a paper (no-op if already assigned).
    public func assign(tagId: String, toPaper paperId: String) throws {
        try dbQueue.write { db in
            try PaperTag(paperId: paperId, tagId: tagId).insert(db, onConflict: .ignore)
        }
    }

    /// Remove a tag from a paper (leaves the tag itself intact).
    public func removeTag(tagId: String, fromPaper paperId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM paper_tag WHERE paper_id = ? AND tag_id = ?",
                arguments: [paperId, tagId]
            )
        }
    }

    /// Deletes a tag entirely. Its paper associations are removed automatically
    /// (paper_tag.tag_id has ON DELETE CASCADE).
    public func deleteTag(id: String) throws {
        try dbQueue.write { _ = try Tag.deleteOne($0, key: id) }
    }

    /// Paper ids that have the given tag.
    public func paperIds(withTag tagId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT paper_id FROM paper_tag WHERE tag_id = ?",
                arguments: [tagId]
            ))
        }
    }

    // MARK: - Helpers

    /// Trims `name` and returns the existing tag with that name, or inserts
    /// and returns a new one. Must be called from within a write transaction.
    private static func findOrCreateTag(named name: String, in db: Database) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try Tag.fetchOne(db, sql: "SELECT * FROM tag WHERE name = ?", arguments: [trimmed]) {
            return existing
        }
        var tag = Tag(name: trimmed)
        try tag.insert(db)
        return tag
    }
}
