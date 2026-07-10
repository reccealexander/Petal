import Foundation
import GRDB

/// Centralizes all database access for highlights and their comments. The
/// view/rendering layer must never touch the DB directly — it goes through
/// this repository instead (spec §1).
public final class HighlightRepository {
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    /// All highlights for a paper, ordered by page then creation time.
    public func highlights(forPaper paperId: String) throws -> [Highlight] {
        try dbQueue.read { db in
            try Highlight.fetchAll(
                db,
                sql: "SELECT * FROM highlight WHERE paper_id = ? ORDER BY page, created_at",
                arguments: [paperId]
            )
        }
    }

    /// Insert multiple highlight rows in a single write transaction.
    public func insertHighlights(_ highlights: [Highlight]) throws {
        try dbQueue.write { db in
            for highlight in highlights {
                try highlight.insert(db)
            }
        }
    }

    /// Delete a highlight by id. Its comments cascade away via the FK (spec §1).
    public func deleteHighlight(id: String) throws {
        try dbQueue.write { db in
            // The highlight's comment(s) cascade away via the FK, but their
            // search_index rows don't — remove those first while the comment
            // ids are still resolvable.
            let commentIds = try String.fetchAll(
                db,
                sql: "SELECT id FROM comment WHERE highlight_id = ?",
                arguments: [id]
            )
            for commentId in commentIds {
                try SearchIndex.remove(entityId: commentId, in: db)
            }
            _ = try Highlight.deleteOne(db, key: id)
        }
    }

    /// A single highlight by id, if it still exists. Used by the reader's
    /// Claude quick actions to resolve the "last opened highlight" back to
    /// its `selectedText` (Session 7 Part C).
    public func highlight(id: String) throws -> Highlight? {
        try dbQueue.read { db in
            try Highlight.fetchOne(db, key: id)
        }
    }

    /// The single comment attached to a highlight, if any.
    public func comment(forHighlight highlightId: String) throws -> Comment? {
        try dbQueue.read { db in
            try Comment.fetchOne(
                db,
                sql: "SELECT * FROM comment WHERE highlight_id = ? ORDER BY created_at LIMIT 1",
                arguments: [highlightId]
            )
        }
    }

    /// Create the highlight's comment, or update the existing one's body.
    /// On update, sets `updated_at` to now. Returns the resulting row.
    @discardableResult
    public func upsertComment(highlightId: String, paperId: String, body: String) throws -> Comment {
        try dbQueue.write { db in
            if var existing = try Comment.fetchOne(
                db,
                sql: "SELECT * FROM comment WHERE highlight_id = ? ORDER BY created_at LIMIT 1",
                arguments: [highlightId]
            ) {
                existing.body = body
                existing.updatedAt = Date()
                try existing.update(db)
                try SearchIndex.indexComment(existing, in: db)
                return existing
            } else {
                let comment = Comment(highlightId: highlightId, paperId: paperId, body: body)
                try comment.insert(db)
                try SearchIndex.indexComment(comment, in: db)
                return comment
            }
        }
    }

    /// Ids of highlights (for this paper) that have at least one comment — used to
    /// draw the "has comment" indicator.
    public func commentedHighlightIds(forPaper paperId: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT highlight_id FROM comment WHERE paper_id = ? AND highlight_id IS NOT NULL",
                arguments: [paperId]
            ))
        }
    }
}
