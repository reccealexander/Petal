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
    /// The cached AI-generated summary of this notebook's papers.
    public var aiSummary: String?
    /// Legacy summary-generation bookkeeping retained for schema compatibility.
    /// Note changes no longer trigger or guard notebook summaries.
    public var aiSummaryNoteCount: Int
    /// SHA-256 of the sorted paper-ID set used to generate `aiSummary`.
    public var aiSummaryPaperIdsHash: String?
    /// Number of papers represented by `aiSummary`, for diagnostics/UI clarity.
    public var aiSummaryPaperCount: Int
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
        aiSummaryPaperIdsHash: String? = nil,
        aiSummaryPaperCount: Int = 0,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.aiSummary = aiSummary
        self.aiSummaryNoteCount = aiSummaryNoteCount
        self.aiSummaryPaperIdsHash = aiSummaryPaperIdsHash
        self.aiSummaryPaperCount = aiSummaryPaperCount
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
        case aiSummaryPaperIdsHash = "ai_summary_paper_ids_hash"
        case aiSummaryPaperCount = "ai_summary_paper_count"
        case pinnedAt = "pinned_at"
    }
}
