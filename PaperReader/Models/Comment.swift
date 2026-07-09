import Foundation
import GRDB

/// A markdown comment. Usually anchored to a highlight (`highlightId`), but the
/// column is nullable so a comment can be attached to a paper directly (spec §1).
/// Cascades from both the highlight and the paper.
public struct Comment: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var highlightId: String?
    public var paperId: String?
    /// Markdown body.
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: String = UUID().uuidString,
        highlightId: String? = nil,
        paperId: String? = nil,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.highlightId = highlightId
        self.paperId = paperId
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "comment"

    enum CodingKeys: String, CodingKey {
        case id
        case highlightId = "highlight_id"
        case paperId = "paper_id"
        case body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
