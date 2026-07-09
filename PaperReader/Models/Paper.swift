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
        lastOpenedAt: Date? = nil
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
    }
}
