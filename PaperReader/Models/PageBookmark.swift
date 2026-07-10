import Foundation
import GRDB

/// A per-paper page earmark shown in the reader thumbnail sidebar.
/// Deleting the parent paper cascades.
public struct PageBookmark: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var paperId: String
    public var page: Int

    public init(id: String = UUID().uuidString, paperId: String, page: Int) {
        self.id = id
        self.paperId = paperId
        self.page = page
    }

    public static let databaseTableName = "page_bookmark"

    enum CodingKeys: String, CodingKey {
        case id
        case paperId = "paper_id"
        case page
    }
}
