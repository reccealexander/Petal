import Foundation
import GRDB

/// Centralizes database access for per-page reader bookmarks.
public final class PageBookmarkRepository {
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    /// All bookmarked page indexes for a paper.
    public func bookmarkedPages(forPaper paperId: String) throws -> Set<Int> {
        try dbQueue.read { db in
            Set(try Int.fetchAll(
                db,
                sql: "SELECT page FROM page_bookmark WHERE paper_id = ?",
                arguments: [paperId]
            ))
        }
    }

    /// Toggles a page bookmark and returns the resulting bookmarked state.
    @discardableResult
    public func toggle(paperId: String, page: Int) throws -> Bool {
        try dbQueue.write { db in
            let exists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM page_bookmark WHERE paper_id = ? AND page = ? LIMIT 1",
                arguments: [paperId, page]
            ) != nil

            if exists {
                try db.execute(
                    sql: "DELETE FROM page_bookmark WHERE paper_id = ? AND page = ?",
                    arguments: [paperId, page]
                )
                return false
            } else {
                try PageBookmark(paperId: paperId, page: page).insert(db)
                return true
            }
        }
    }

    /// Whether a page is bookmarked for a paper.
    public func isBookmarked(paperId: String, page: Int) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM page_bookmark WHERE paper_id = ? AND page = ? LIMIT 1",
                arguments: [paperId, page]
            ) != nil
        }
    }
}
