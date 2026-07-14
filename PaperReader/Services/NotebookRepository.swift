import Foundation
import GRDB

/// Thrown by `move(id:toParent:)` when the requested re-parent would make a
/// notebook its own ancestor.
public enum NotebookError: Error {
    case wouldCreateCycle
}

/// Centralizes all database access for notebooks (the folder tree) and the
/// papers filed under them. The view/rendering layer must never touch the DB
/// directly — it goes through this repository instead (spec §1).
public final class NotebookRepository {
    private let database: DatabaseManager
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.database = database
        self.dbQueue = database.dbQueue
    }

    /// All notebooks, ordered by sortOrder then name (caller builds the tree from parentId).
    public func allNotebooks() throws -> [Notebook] {
        try dbQueue.read { db in
            try Notebook.fetchAll(db, sql: "SELECT * FROM notebook ORDER BY sort_order, name")
        }
    }

    /// Notebooks whose names contain `query`, case-insensitively. This is kept
    /// deliberately lightweight because notebooks are not part of the FTS5
    /// `search_index` used for paper content.
    public func notebooks(matchingName query: String, limit: Int = 20) throws -> [Notebook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Notebook.fetchAll(
                db,
                sql: """
                SELECT * FROM notebook
                WHERE name LIKE '%' || ? || '%' COLLATE NOCASE
                ORDER BY name COLLATE NOCASE
                LIMIT ?
                """,
                arguments: [trimmed, max(0, limit)]
            )
        }
    }

    /// A single notebook by id, or nil if it doesn't exist (Session 7 Part B:
    /// used to resolve a paper's containing notebook for the Claude panel's
    /// paper/notebook mode switcher).
    public func notebook(id: String) throws -> Notebook? {
        try dbQueue.read { db in
            try Notebook.fetchOne(db, key: id)
        }
    }

    /// Creates a new notebook (optionally nested under `parentId`) and persists it.
    @discardableResult
    public func create(name: String, parentId: String?) throws -> Notebook {
        let notebook = Notebook(name: name, parentId: parentId)
        try dbQueue.write { db in
            try notebook.insert(db)
        }
        return notebook
    }

    /// Renames an existing notebook.
    public func rename(id: String, to name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE notebook SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Deletes a notebook. Nested notebooks cascade-delete (FK ON DELETE CASCADE);
    /// papers in the subtree are orphaned to Unfiled (paper.notebook_id ON DELETE SET NULL).
    public func delete(id: String) throws {
        try dbQueue.write { db in
            _ = try Notebook.deleteOne(db, key: id)
        }
    }

    /// Re-parent a notebook. Throws NotebookError.wouldCreateCycle if `newParentId`
    /// is the notebook itself or any of its descendants.
    public func move(id: String, toParent newParentId: String?) throws {
        try dbQueue.write { db in
            if let newParentId {
                let descendantIds = try String.fetchSet(
                    db,
                    sql: """
                    WITH RECURSIVE sub(id) AS (
                        SELECT id FROM notebook WHERE id = :root
                        UNION ALL
                        SELECT n.id FROM notebook n JOIN sub s ON n.parent_id = s.id
                    ) SELECT id FROM sub
                    """,
                    arguments: ["root": id]
                )
                if newParentId == id || descendantIds.contains(newParentId) {
                    throw NotebookError.wouldCreateCycle
                }
            }
            try db.execute(
                sql: "UPDATE notebook SET parent_id = ? WHERE id = ?",
                arguments: [newParentId, id]
            )
        }
    }

    /// Move a paper into a notebook (or nil for Unfiled).
    public func movePaper(paperId: String, toNotebook notebookId: String?) throws {
        let affectedNotebookIds = try dbQueue.write { db -> Set<String> in
            guard let paperRow = try Row.fetchOne(
                db,
                sql: "SELECT notebook_id FROM paper WHERE id = ?",
                arguments: [paperId]
            ) else { return [] }
            let oldNotebookId: String? = paperRow["notebook_id"]
            guard oldNotebookId != notebookId else { return [] }

            var affected = try Self.notebookAndAncestorIds(for: oldNotebookId, in: db)
            affected.formUnion(try Self.notebookAndAncestorIds(for: notebookId, in: db))
            try db.execute(
                sql: "UPDATE paper SET notebook_id = ? WHERE id = ?",
                arguments: [notebookId, paperId]
            )
            return affected
        }
        requestSummaryChecks(for: affectedNotebookIds)
    }

    /// Deletes paper rows and their non-FK search/chat bookkeeping in one
    /// transaction, then requests summary checks for every affected notebook.
    /// The returned rows let the caller remove the corresponding managed files.
    @discardableResult
    public func deletePapers(ids: Set<String>) throws -> [Paper] {
        guard !ids.isEmpty else { return [] }

        let result = try dbQueue.write { db -> (papers: [Paper], notebookIds: Set<String>) in
            var papers: [Paper] = []
            var affectedNotebookIds: Set<String> = []
            for id in ids {
                guard let paper = try Paper.fetchOne(db, key: id) else { continue }
                papers.append(paper)
                affectedNotebookIds.formUnion(
                    try Self.notebookAndAncestorIds(for: paper.notebookId, in: db)
                )
                try db.execute(
                    sql: "DELETE FROM chat_session WHERE scope = 'paper' AND scope_id = ?",
                    arguments: [id]
                )
                try db.execute(
                    sql: "DELETE FROM search_index WHERE paper_id = ?",
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM paper WHERE id = ?", arguments: [id])
            }
            return (papers, affectedNotebookIds)
        }
        requestSummaryChecks(for: result.notebookIds)
        return result.papers
    }

    /// Includes ancestors because `papersUnder` gives every ancestor a
    /// recursive paper set that changes when a descendant gains/loses a paper.
    private static func notebookAndAncestorIds(for notebookId: String?, in db: Database) throws -> Set<String> {
        guard let notebookId else { return [] }
        return try String.fetchSet(
            db,
            sql: """
            WITH RECURSIVE ancestors(id) AS (
                SELECT id FROM notebook WHERE id = ?
                UNION ALL
                SELECT n.parent_id
                FROM notebook n JOIN ancestors a ON n.id = a.id
                WHERE n.parent_id IS NOT NULL
            )
            SELECT id FROM ancestors
            """,
            arguments: [notebookId]
        )
    }

    private func requestSummaryChecks(for notebookIds: Set<String>) {
        guard !notebookIds.isEmpty else { return }
        let summaryService = NotebookSummaryService(database: database)
        for notebookId in notebookIds {
            summaryService.notebookPaperSetChanged(notebookId: notebookId)
        }
    }

    /// All papers in this notebook AND its descendants (recursive CTE, spec §1),
    /// ordered by imported_at desc.
    public func papersUnder(notebookId: String) throws -> [Paper] {
        try dbQueue.read { db in
            try Paper.fetchAll(
                db,
                sql: """
                WITH RECURSIVE sub_notebooks(id) AS (
                    SELECT id FROM notebook WHERE id = ?
                    UNION ALL
                    SELECT n.id FROM notebook n JOIN sub_notebooks s ON n.parent_id = s.id
                )
                SELECT * FROM paper WHERE notebook_id IN (SELECT id FROM sub_notebooks) ORDER BY imported_at DESC
                """,
                arguments: [notebookId]
            )
        }
    }

    /// Every paper, ordered by imported_at desc.
    public func allPapers() throws -> [Paper] {
        try dbQueue.read { db in
            try Paper.fetchAll(db, sql: "SELECT * FROM paper ORDER BY imported_at DESC")
        }
    }

    /// The most-recently-opened papers, ordered by `last_opened_at` descending.
    /// Only papers that have actually been opened (non-null `last_opened_at`)
    /// are included, capped at `limit`. `last_opened_at` is stamped by the
    /// reader on open, so this list re-orders naturally as papers are read.
    public func recentlyViewedPapers(limit: Int = 10) throws -> [Paper] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            try Paper.fetchAll(
                db,
                sql: """
                SELECT * FROM paper
                WHERE last_opened_at IS NOT NULL
                ORDER BY last_opened_at DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    /// Papers not in any notebook (notebook_id IS NULL).
    public func unfiledPapers() throws -> [Paper] {
        try dbQueue.read { db in
            try Paper.fetchAll(
                db,
                sql: "SELECT * FROM paper WHERE notebook_id IS NULL ORDER BY imported_at DESC"
            )
        }
    }

    /// Pins or unpins a paper (Session 12): sets `pinned_at` to now, or clears it.
    public func setPaperPinned(paperId: String, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE paper SET pinned_at = ? WHERE id = ?",
                arguments: [pinned ? Date() : nil, paperId]
            )
        }
    }

    /// Pins or unpins a notebook (Session 12): sets `pinned_at` to now, or clears it.
    public func setNotebookPinned(id: String, pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE notebook SET pinned_at = ? WHERE id = ?",
                arguments: [pinned ? Date() : nil, id]
            )
        }
    }

    /// Sets a paper's free-space canvas position (Session 12). Pass nil for
    /// both to mark it unplaced again.
    public func setPaperPosition(paperId: String, x: Double?, y: Double?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE paper SET free_space_x = ?, free_space_y = ? WHERE id = ?",
                arguments: [x, y, paperId]
            )
        }
    }

    /// Persists the exact PDFKit destination used to resume reading.
    public func setResumePosition(paperId: String, page: Int, offset: Double) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE paper SET last_page = ?, last_scroll_offset = ?,
                    furthest_page_read = MAX(furthest_page_read, ?) WHERE id = ?
                """,
                arguments: [page, offset, page + 1, paperId]
            )
        }
    }

    /// Updates the Session 17 reading state independently of reader recency.
    public func setReadingStatus(paperId: String, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE paper SET reading_status = ? WHERE id = ?",
                arguments: [status, paperId]
            )
        }
    }

    /// True if this notebook or any descendant contains at least one paper (for the delete confirm).
    public func containsPapers(notebookId: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                WITH RECURSIVE sub_notebooks(id) AS (
                    SELECT id FROM notebook WHERE id = ?
                    UNION ALL
                    SELECT n.id FROM notebook n JOIN sub_notebooks s ON n.parent_id = s.id
                )
                SELECT EXISTS(SELECT 1 FROM paper WHERE notebook_id IN (SELECT id FROM sub_notebooks))
                """,
                arguments: [notebookId]
            ) ?? false
        }
    }
}
