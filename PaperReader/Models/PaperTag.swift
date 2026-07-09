import Foundation
import GRDB

/// Join row for the many-to-many relationship between `Paper` and `Tag`
/// (spec §1). Composite primary key `(paper_id, tag_id)`; both sides cascade.
public struct PaperTag: Codable, Hashable, FetchableRecord, PersistableRecord {
    public var paperId: String
    public var tagId: String

    public init(paperId: String, tagId: String) {
        self.paperId = paperId
        self.tagId = tagId
    }

    public static let databaseTableName = "paper_tag"

    enum CodingKeys: String, CodingKey {
        case paperId = "paper_id"
        case tagId = "tag_id"
    }
}
