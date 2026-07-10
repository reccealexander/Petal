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
    /// The cached AI-generated summary of this notebook's papers/highlights/
    /// notes (Session 10), or nil if none has been generated yet.
    public var aiSummary: String?
    /// The notebook's total note count at the time `aiSummary` was last
    /// generated — compared against the current count to decide whether a
    /// regenerate is due (see `NotebookSummaryService`).
    public var aiSummaryNoteCount: Int
    /// Non-nil when the notebook is pinned (Session 12); the timestamp orders
    /// pinned items.
    public var pinnedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        parentId: String? = nil,
        createdAt: Date = Date(),
        sortOrder: Int = 0,
        aiSummary: String? = nil,
        aiSummaryNoteCount: Int = 0,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.aiSummary = aiSummary
        self.aiSummaryNoteCount = aiSummaryNoteCount
        self.pinnedAt = pinnedAt
    }

    public static let databaseTableName = "notebook"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentId = "parent_id"
        case createdAt = "created_at"
        case sortOrder = "sort_order"
        case aiSummary = "ai_summary"
        case aiSummaryNoteCount = "ai_summary_note_count"
        case pinnedAt = "pinned_at"
    }
}
