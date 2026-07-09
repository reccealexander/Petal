import Foundation
import GRDB

/// A highlighted region on a paper page. `boundingBoxes` is a JSON array of CGRect
/// (stored as TEXT), `color` maps to a user-assignable category (spec §1).
/// Deleting the parent paper cascades.
public struct Highlight: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    public var id: String
    public var paperId: String?
    public var page: Int
    /// JSON-encoded array of CGRect describing the highlighted rects on the page.
    public var boundingBoxes: String
    public var color: String
    public var selectedText: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        paperId: String?,
        page: Int,
        boundingBoxes: String,
        color: String = "yellow",
        selectedText: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.paperId = paperId
        self.page = page
        self.boundingBoxes = boundingBoxes
        self.color = color
        self.selectedText = selectedText
        self.createdAt = createdAt
    }

    public static let databaseTableName = "highlight"

    enum CodingKeys: String, CodingKey {
        case id
        case paperId = "paper_id"
        case page
        case boundingBoxes = "bounding_boxes"
        case color
        case selectedText = "selected_text"
        case createdAt = "created_at"
    }
}
