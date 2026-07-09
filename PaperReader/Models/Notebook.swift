import Foundation
import GRDB

/// A folder in the notebook tree. `parentId` self-references `notebook.id`, which
/// gives arbitrary nesting (spec §1). Deleting a notebook cascades to its children.
public struct Notebook: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var name: String
    public var parentId: String?
    public var createdAt: Date
    public var sortOrder: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        parentId: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }

    public static let databaseTableName = "notebook"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentId = "parent_id"
        case createdAt = "created_at"
        case sortOrder = "sort_order"
    }
}
