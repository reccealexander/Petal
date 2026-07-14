import Foundation
import GRDB

/// A user-defined tag. `name` is unique (spec §1). Linked to papers many-to-many
/// through `PaperTag`.
public struct Tag: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public static let databaseTableName = "tag"

    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}
