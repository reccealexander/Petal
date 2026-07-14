import Foundation
import PaperReaderCore

/// Bridges the SwiftUI reader toolbar to the PDFKit coordinator. The coordinator
/// sets `performAddHighlight` once the PDFView exists; the toolbar calls `addHighlight`.
@MainActor
final class PDFReaderModel: ObservableObject {
    enum SidebarMode: String, CaseIterable, Identifiable {
        case thumbnails
        case chapters

        var id: Self { self }

        var label: String {
            switch self {
            case .thumbnails: "Thumbnails"
            case .chapters: "Chapters"
            }
        }
    }

    @Published var hasSelection = false
    @Published var isAIAssistModeActive = false
    @Published var isSuggestingKeyIdeas = false
    @Published var keyIdeaProposals: [KeyIdeaProposal] = []
    @Published var keyIdeaError: String?

    var performAddHighlight: ((HighlightColor) -> Void)?
    func addHighlight(_ color: HighlightColor) { performAddHighlight?(color) }

    var performSuggestKeyIdeas: (() -> Void)?
    func suggestKeyIdeas() { performSuggestKeyIdeas?() }
    var performAcceptKeyIdea: ((UUID) -> Void)?
    func acceptKeyIdea(_ id: UUID) { performAcceptKeyIdea?(id) }
    var performAcceptAllKeyIdeas: (() -> Void)?
    func acceptAllKeyIdeas() { performAcceptAllKeyIdeas?() }
    var performDismissKeyIdea: ((UUID) -> Void)?
    func dismissKeyIdea(_ id: UUID) { performDismissKeyIdea?(id) }
    var performClearKeyIdeaProposals: (() -> Void)?
    func clearKeyIdeaProposals() { performClearKeyIdeaProposals?() }
    var provideHasGeminiKey: (() -> Bool)?
    func hasGeminiKey() -> Bool { provideHasGeminiKey?() ?? false }

    /// Index of the page currently in view, kept in sync by the coordinator's
    /// `.PDFViewPageChanged` observer. The thumbnail sidebar reads this to
    /// highlight the current row and auto-scroll it into view.
    @Published var currentPageIndex: Int = 0
    /// Set by the coordinator; jumps the PDFView to a given page index.
    var performGoToPage: ((Int) -> Void)?
    func goToPage(_ index: Int) { performGoToPage?(index) }

    /// Set by the coordinator so reader teardown can synchronously persist the
    /// current PDF destination instead of waiting for the debounce timer.
    var performSaveResumePositionNow: (() -> Void)?
    func saveResumePositionNow() { performSaveResumePositionNow?() }

    /// Whether the page-thumbnail sidebar is shown. Defaults to visible.
    @Published var isThumbnailSidebarVisible: Bool = true

    /// The content shown in the reader's left sidebar.
    @Published var sidebarMode: SidebarMode = .thumbnails

    /// Whether the Claude Q&A side panel is shown. Defaults to hidden — it
    /// slides in from the trailing edge when toggled from the toolbar.
    @Published var isClaudePanelVisible: Bool = false

    /// Last scope selected in the reader chat, carried into Focus-mode chat windows.
    @Published var chatScopeIsNotebook: Bool = false

    // MARK: - Quick-action context providers (Session 7 Part C)
    //
    // Set by `PDFKitWrapper.Coordinator` in `makeNSView`, same pattern as
    // `performAddHighlight`/`performGoToPage` above. The Claude panel's
    // quick-action buttons call the `...Text()`/`openHighlight()`
    // convenience methods below (via a `ReaderQuickActionSource`) rather
    // than reaching into PDFKit directly, keeping the view/PDFKit coupling
    // in one place.

    /// Returns the current PDF text selection, trimmed, or nil if empty.
    var provideSelectionText: (() -> String?)?
    /// Returns text surrounding the selection (approximated by the current
    /// page's full text).
    var provideSurroundingText: (() -> String?)?
    /// Returns the current page's full text.
    var providePageText: (() -> String?)?
    /// Returns the last-opened/selected highlight's text and comment, if any.
    var provideOpenHighlight: (() -> (text: String, comment: String?)?)?

    func selectionText() -> String? { provideSelectionText?() }
    func surroundingText() -> String? { provideSurroundingText?() }
    func pageText() -> String? { providePageText?() }
    func openHighlight() -> (text: String, comment: String?)? { provideOpenHighlight?() }
}
