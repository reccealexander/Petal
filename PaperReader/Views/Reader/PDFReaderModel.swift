import Foundation
import PaperReaderCore

/// Bridges the SwiftUI reader toolbar to the PDFKit coordinator. The coordinator
/// sets `performAddHighlight` once the PDFView exists; the toolbar calls `addHighlight`.
@MainActor
final class PDFReaderModel: ObservableObject {
    @Published var hasSelection = false
    var performAddHighlight: ((HighlightColor) -> Void)?
    func addHighlight(_ color: HighlightColor) { performAddHighlight?(color) }
}
