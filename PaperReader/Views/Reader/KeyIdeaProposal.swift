import Foundation
import CoreGraphics

/// One pending AI key-idea suggestion located on a specific page. Ephemeral —
/// never persisted until the user accepts it (then it becomes an ordinary Highlight).
struct KeyIdeaProposal: Identifiable, Equatable {
    let id: UUID
    let sentence: String
    let pageIndex: Int
    let rects: [CGRect]
}
