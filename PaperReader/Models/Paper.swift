import Foundation
import GRDB

/// A single imported PDF and its metadata. `filePath` is stored relative to the
/// `Papers/` directory (spec §1). Deleting the parent notebook sets `notebookId`
/// to NULL rather than deleting the paper.
public struct Paper: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var notebookId: String?
    public var title: String?
    public var authors: String?
    public var doi: String?
    public var arxivId: String?
    public var filePath: String
    public var fileHash: String?
    public var pageCount: Int?
    public var importedAt: Date
    public var lastOpenedAt: Date?
    /// Position on the free-space canvas (Session 12); nil means the paper
    /// hasn't been placed yet.
    public var freeSpaceX: Double?
    public var freeSpaceY: Double?
    /// Non-nil when the paper is pinned (Session 12); the timestamp orders
    /// pinned items.
    public var pinnedAt: Date?

    public init(
        id: String = UUID().uuidString,
        notebookId: String? = nil,
        title: String? = nil,
        authors: String? = nil,
        doi: String? = nil,
        arxivId: String? = nil,
        filePath: String,
        fileHash: String? = nil,
        pageCount: Int? = nil,
        importedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        freeSpaceX: Double? = nil,
        freeSpaceY: Double? = nil,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.notebookId = notebookId
        self.title = title
        self.authors = authors
        self.doi = doi
        self.arxivId = arxivId
        self.filePath = filePath
        self.fileHash = fileHash
        self.pageCount = pageCount
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.freeSpaceX = freeSpaceX
        self.freeSpaceY = freeSpaceY
        self.pinnedAt = pinnedAt
    }

    public static let databaseTableName = "paper"

    enum CodingKeys: String, CodingKey {
        case id
        case notebookId = "notebook_id"
        case title
        case authors
        case doi
        case arxivId = "arxiv_id"
        case filePath = "file_path"
        case fileHash = "file_hash"
        case pageCount = "page_count"
        case importedAt = "imported_at"
        case lastOpenedAt = "last_opened_at"
        case freeSpaceX = "free_space_x"
        case freeSpaceY = "free_space_y"
        case pinnedAt = "pinned_at"
    }
}
