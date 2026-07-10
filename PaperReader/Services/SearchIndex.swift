import Foundation
import GRDB

/// The kind of entity a search hit refers to.
public enum SearchEntityType: String, Codable, Sendable {
    case paper, note, comment
}

/// A single FTS5 search hit.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public let id: String            // entity_id
    public let entityType: SearchEntityType
    public let paperId: String?
    public let snippet: String       // matched excerpt
}

/// Low-level upserts into the `search_index` FTS5 table. These run *inside* an
/// existing write transaction so indexing stays consistent with the row change.
public enum SearchIndex {
    /// Replace the index row for a paper (content = title + authors).
    public static func indexPaper(_ paper: Paper, in db: Database) throws {
        let content = [paper.title, paper.authors].compactMap { $0 }.joined(separator: " ")
        try upsert(entityId: paper.id, type: .paper, paperId: paper.id, content: content, in: db)
    }

    /// Replace the index row for a note (content = body).
    public static func indexNote(_ note: Note, in db: Database) throws {
        try upsert(entityId: note.id, type: .note, paperId: note.paperId, content: note.body, in: db)
    }

    /// Replace the index row for a comment (content = body).
    public static func indexComment(_ comment: Comment, in db: Database) throws {
        try upsert(entityId: comment.id, type: .comment, paperId: comment.paperId, content: comment.body, in: db)
    }

    /// Remove any index row for an entity id.
    public static func remove(entityId: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM search_index WHERE entity_id = ?", arguments: [entityId])
    }

    /// Deletes any existing row for `entityId` then inserts the fresh one, so
    /// updates don't duplicate rows in the FTS index.
    private static func upsert(
        entityId: String,
        type: SearchEntityType,
        paperId: String?,
        content: String,
        in db: Database
    ) throws {
        try remove(entityId: entityId, in: db)
        try db.execute(
            sql: "INSERT INTO search_index (entity_id, entity_type, paper_id, content) VALUES (?, ?, ?, ?)",
            arguments: [entityId, type.rawValue, paperId, content]
        )
    }
}
