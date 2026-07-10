import Foundation
import PaperReaderCore

/// Bridges the SwiftUI reader toolbar to the PDFKit coordinator. The coordinator
/// sets `performAddHighlight` once the PDFView exists; the toolbar calls `addHighlight`.
@MainActor
final class PDFReaderModel: ObservableObject {
    @Published var hasSelection = false
    var performAddHighlight: ((HighlightColor) -> Void)?
    func addHighlight(_ color: HighlightColor) { performAddHighlight?(color) }

    /// Index of the page currently in view, kept in sync by the coordinator's
    /// `.PDFViewPageChanged` observer. The thumbnail sidebar reads this to
    /// highlight the current row and auto-scroll it into view.
    @Published var currentPageIndex: Int = 0
    /// Set by the coordinator; jumps the PDFView to a given page index.
    var performGoToPage: ((Int) -> Void)?
    func goToPage(_ index: Int) { performGoToPage?(index) }

    /// Whether the page-thumbnail sidebar is shown. Defaults to visible.
    @Published var isThumbnailSidebarVisible: Bool = true

    /// Whether the Claude Q&A side panel is shown. Defaults to hidden — it
    /// slides in from the trailing edge when toggled from the toolbar.
    @Published var isClaudePanelVisible: Bool = false
}
