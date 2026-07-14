import Foundation
import GRDB

/// Read-only full-text search over the `search_index` FTS5 table. The
/// view/rendering layer must never touch the DB directly — it goes through
/// this repository instead (spec §1).
public final class SearchRepository {
    private let dbQueue: DatabaseQueue

    /// Creates the repository, reading its storage handle from `database`.
    public init(database: DatabaseManager) {
        self.dbQueue = database.dbQueue
    }

    /// Full-text search across papers/notes/comments, ranked by FTS5 `rank`.
    /// Returns [] for an empty/blank query.
    public func search(_ query: String) throws -> [SearchResult] {
        guard let ftsQuery = Self.ftsQuery(from: query) else {
            return []
        }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT entity_id, entity_type, paper_id,
                       snippet(search_index, 3, '', '', '…', 12) AS snip
                FROM search_index
                WHERE search_index MATCH ?
                ORDER BY rank
                LIMIT 100
                """, arguments: [ftsQuery])
            .compactMap { row in
                guard let type = SearchEntityType(rawValue: row["entity_type"]) else { return nil }
                return SearchResult(id: row["entity_id"], entityType: type,
                                     paperId: row["paper_id"], snippet: row["snip"] ?? "")
            }
        }
    }

    /// Builds a safe FTS5 MATCH query from free-form user input: tokenizes into
    /// alphanumeric runs and turns each into a quoted prefix term (`"token"*`),
    /// so punctuation in the query can't produce an invalid FTS5 expression.
    /// Returns nil if the query has no tokens.
    private static func ftsQuery(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return nil }

        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}
