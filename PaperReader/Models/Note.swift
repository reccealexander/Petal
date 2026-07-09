import Foundation
import GRDB

/// A free-form markdown note, scoped to a paper and/or a notebook (both nullable,
/// spec §1). `linkedHighlightIds` is a JSON array of highlight ids referenced by
/// the note. Cascades from paper and notebook.
public struct Note: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var paperId: String?
    public var notebookId: String?
    public var title: String?
    /// Markdown body.
    public var body: String
    /// JSON-encoded array of linked highlight ids.
    public var linkedHighlightIds: String?
    public var createdAt: Date
    public var updatedAt: Date?

    public init(
        id: String = UUID().uuidString,
        paperId: String? = nil,
        notebookId: String? = nil,
        title: String? = nil,
        body: String,
        linkedHighlightIds: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.paperId = paperId
        self.notebookId = notebookId
        self.title = title
        self.body = body
        self.linkedHighlightIds = linkedHighlightIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "note"

    enum CodingKeys: String, CodingKey {
        case id
        case paperId = "paper_id"
        case notebookId = "notebook_id"
        case title
        case body
        case linkedHighlightIds = "linked_highlight_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
