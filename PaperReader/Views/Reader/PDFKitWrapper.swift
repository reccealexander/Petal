import SwiftUI
import PDFKit
import AppKit
import GRDB
import PaperReaderCore

/// PDFView subclass that gives the coordinator first chance to handle a click that
/// lands on a highlight annotation (opening the comment popover) before PDFView's
/// own selection handling runs.
final class AnnotatablePDFView: PDFView {
    /// Returns true if the click hit a tracked highlight and was handled (consume the event).
    var onAnnotationClick: ((PDFAnnotation, PDFPage) -> Bool)?
    /// Maps an annotation back to the highlight id it belongs to (nil if untracked).
    var highlightId: ((PDFAnnotation) -> String?)?
    /// Deletes the highlight with the given id.
    var onDeleteHighlight: ((String) -> Void)?
    /// Chapter navigation is handled here so Command-arrow shortcuts only
    /// participate while this PDF view is the keyboard's first responder.
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?

    private var pendingDeleteHighlightId: String?

    override func mouseDown(with event: NSEvent) {
        // Annotation clicks can return before PDFView's implementation gets a
        // chance to establish focus, so make the clicked reader explicit.
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false) {
            let pagePoint = convert(viewPoint, to: page)
            if let annotation = page.annotation(at: pagePoint),
               onAnnotationClick?(annotation, page) == true {
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let shortcutModifiers = event.modifierFlags.intersection([
            .command, .option, .control, .shift
        ])
        if shortcutModifiers == .command {
            switch event.specialKey {
            case .rightArrow:
                onNextChapter?()
                return
            case .leftArrow:
                onPreviousChapter?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Right-clicking a tracked highlight offers to delete it; otherwise falls
    /// back to PDFView's default contextual menu (copy, etc.).
    override func menu(for event: NSEvent) -> NSMenu? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false) {
            let pagePoint = convert(viewPoint, to: page)
            if let annotation = page.annotation(at: pagePoint),
               let id = highlightId?(annotation) {
                pendingDeleteHighlightId = id
                let menu = NSMenu()
                let item = NSMenuItem(
                    title: "Delete Highlight",
                    action: #selector(deleteHighlightMenuAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
                return menu
            }
        }
        return super.menu(for: event)
    }

    @objc private func deleteHighlightMenuAction(_ sender: NSMenuItem) {
        if let id = pendingDeleteHighlightId { onDeleteHighlight?(id) }
        pendingDeleteHighlightId = nil
    }
}

/// `NSViewRepresentable` bridge around `PDFKit.PDFView` (spec §3 Phase 1).
///
/// Renders the PDF at `url` as a continuous, auto-scaling, vertically-scrolling
/// document — the standard "reader" presentation. Swapping in a new `url` (e.g.
/// opening a different paper in the same view) reloads the document in place.
///
/// Also wires up the highlight/comment annotation loop: the coordinator draws
/// every persisted `Highlight` (+ "has comment" dot) as `PDFAnnotation`s on
/// load, adds new ones when the toolbar asks for a highlight of the current
/// selection, and opens a comment popover when a highlight annotation is
/// clicked. The database is the source of truth — highlights are rebuilt from
/// it on every load, never assumed to persist across `PDFView` instances.
struct PDFKitWrapper: NSViewRepresentable {
    /// Absolute file URL of the PDF to display.
    let url: URL
    let paper: Paper
    let database: DatabaseManager
    @ObservedObject var model: PDFReaderModel
    var isFocusModeActive = false
    let onNextChapter: () -> Void
    let onPreviousChapter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            paper: paper,
            model: model,
            repository: HighlightRepository(database: database),
            notebookRepository: NotebookRepository(database: database)
        )
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = AnnotatablePDFView()
        // Session 8: default-on-open zoom is native page size (100%),
        // managed ourselves rather than via `autoScales` (which would
        // stretch every page to fill the often-very-wide window). PDFKit
        // centers a page narrower than the view for free, so this yields
        // natural margins on wide windows. See
        // `Coordinator.applyInitialZoomIfNeeded()` for the one-shot apply.
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5.0
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        pdfView.backgroundColor = isFocusModeActive ? .clear : .controlBackgroundColor

        let coord = context.coordinator
        coord.pdfView = pdfView
        pdfView.onAnnotationClick = { [weak coord] annotation, page in
            coord?.handleAnnotationClick(annotation, page: page) ?? false
        }
        pdfView.highlightId = { [weak coord] annotation in coord?.annotationToId[annotation] }
        pdfView.onDeleteHighlight = { [weak coord] id in coord?.deleteHighlight(id) }
        pdfView.onNextChapter = onNextChapter
        pdfView.onPreviousChapter = onPreviousChapter
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.jumpRequested(_:)),
            name: .readerJumpToHighlight, object: nil)
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: pdfView)
        if let clipView = pdfView.documentView?.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                coord, selector: #selector(Coordinator.scrollChanged(_:)),
                name: NSView.boundsDidChangeNotification, object: clipView)
        }
        model.performAddHighlight = { [weak coord] color in coord?.addHighlight(color) }
        model.performGoToPage = { [weak coord] index in coord?.goToPage(index) }
        model.performSaveResumePositionNow = { [weak coord] in coord?.saveResumePositionNow() }
        model.provideSelectionText = { [weak coord] in coord?.currentSelectionText() }
        model.provideSurroundingText = { [weak coord] in coord?.currentPageText() }
        model.providePageText = { [weak coord] in coord?.currentPageText() }
        model.provideOpenHighlight = { [weak coord] in coord?.openHighlightForQuickAction() }
        model.performSuggestKeyIdeas = { [weak coord] in coord?.fetchOrRenderCurrentPage() }
        model.performAcceptKeyIdea = { [weak coord] id in coord?.acceptKeyIdea(id) }
        model.performAcceptAllKeyIdeas = { [weak coord] in coord?.acceptAllKeyIdeas() }
        model.performDismissKeyIdea = { [weak coord] id in coord?.dismissKeyIdea(id) }
        model.performClearKeyIdeaProposals = { [weak coord] in coord?.clearKeyIdeaProposals() }
        model.provideHasGeminiKey = { [weak coord] in coord?.keyIdeaService.hasAPIKey ?? false }
        coord.rehydrate()

        // The view's bounds are typically still zero at this point (SwiftUI
        // hasn't laid it out yet), so `scaleFactorForSizeToFit` would be
        // unreliable if computed synchronously here. Defer to the next run
        // loop turn, by which point AppKit has given the view its real size.
        DispatchQueue.main.async { [weak coord] in
            coord?.applyInitialZoomIfNeeded()
        }

        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.backgroundColor = isFocusModeActive ? .clear : .controlBackgroundColor
        if let pdfView = nsView as? AnnotatablePDFView {
            pdfView.onNextChapter = onNextChapter
            pdfView.onPreviousChapter = onPreviousChapter
        }
        if nsView.document?.documentURL != url {
            context.coordinator.clearKeyIdeaProposals()
            nsView.document = PDFDocument(url: url)
            context.coordinator.didApplyInitialZoom = false
            context.coordinator.rehydrate()
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                coordinator?.applyInitialZoomIfNeeded()
            }
        }
    }

    /// Owns the PDFKit-facing state that has no place in SwiftUI: the live
    /// mapping from tracked `PDFAnnotation`s back to `Highlight` ids, and the
    /// comment popover. `@MainActor` because it touches `model` (an
    /// `ObservableObject`) and AppKit UI directly.
    @MainActor
    final class Coordinator: NSObject {
        let paperId: String
        let paper: Paper
        let model: PDFReaderModel
        let repository: HighlightRepository
        let notebookRepository: NotebookRepository
        weak var pdfView: AnnotatablePDFView?
        var tracked: [PDFAnnotation] = []
        var annotationToId: [PDFAnnotation: String] = [:]
        private var proposalsByPage: [Int: [KeyIdeaProposal]] = [:]
        private var proposedAnnotations: [KeyIdeaProposal.ID: [PDFAnnotation]] = [:]
        private var fetchedPages: Set<Int> = []
        private var inFlightPages: Set<Int> = []
        private var autoSuggestTask: Task<Void, Never>?
        private var proposalGeneration = 0
        let keyIdeaService = KeyIdeaSuggestionService()
        var popover: NSPopover?

        /// The id of the highlight most recently opened (comment popover shown)
        /// or clicked, tracked for the "Explain this highlight" quick action
        /// (Session 7 Part C). Cleared implicitly when the highlight is
        /// deleted (the id simply stops resolving).
        var lastOpenedHighlightId: String?

        /// Set once the one-shot initial page-fit zoom has been applied, so
        /// we never override a zoom level the user has since chosen
        /// themselves (Feature 2 — page-size opening).
        var didApplyInitialZoom = false
        private var runningFurthestPageRead: Int
        private let pageCount: Int?
        private var didAutoMarkRead = false

        private lazy var resumeAutosave = AutosaveController(debounce: 1.0) { [weak self] in
            self?.persistResumePosition()
        }

        init(
            paper: Paper,
            model: PDFReaderModel,
            repository: HighlightRepository,
            notebookRepository: NotebookRepository
        ) {
            self.paperId = paper.id
            self.paper = paper
            self.model = model
            self.repository = repository
            self.notebookRepository = notebookRepository
            self.runningFurthestPageRead = paper.furthestPageRead
            self.pageCount = paper.pageCount
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func selectionChanged(_ note: Notification) {
            model.hasSelection = (pdfView?.currentSelection?.string?.isEmpty == false)
        }

        /// Keeps `model.currentPageIndex` in sync as the user scrolls or jumps,
        /// so the thumbnail sidebar can highlight and auto-scroll to match.
        @objc func pageChanged(_ note: Notification) {
            guard let pdfView, let document = pdfView.document,
                  let page = pdfView.currentPage
            else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }
            model.currentPageIndex = pageIndex
            if model.isAIAssistModeActive {
                renderProposals(forPage: pageIndex)
                updateSuggestionLoadingState()
                autoSuggestCurrentPageIfNeeded()
            } else {
                removeDrawnProposalAnnotations()
            }
            resumeAutosave.schedule()
        }

        /// PDFKit does not emit a page change while scrolling within one page,
        /// so bounds changes also feed the same lightweight debounce.
        @objc func scrollChanged(_ note: Notification) {
            resumeAutosave.schedule()
        }

        func saveResumePositionNow() {
            resumeAutosave.cancel()
            persistResumePosition()
        }

        private func persistResumePosition() {
            guard let pdfView,
                  let document = pdfView.document,
                  let destination = pdfView.currentDestination,
                  let destinationPage = destination.page
            else { return }
            let page = document.index(for: destinationPage)
            guard page != NSNotFound else { return }
            do {
                try notebookRepository.setResumePosition(
                    paperId: paperId,
                    page: page,
                    offset: Double(destination.point.y)
                )
                let reached = page + 1
                let previousFurthest = runningFurthestPageRead
                runningFurthestPageRead = max(runningFurthestPageRead, reached)
                if !didAutoMarkRead,
                   let pageCount, pageCount > 0,
                   previousFurthest < pageCount,
                   runningFurthestPageRead >= pageCount {
                    try notebookRepository.setReadingStatus(paperId: paperId, status: "read")
                    didAutoMarkRead = true
                }
            } catch {
                // Resume autosave is best-effort; a later page/scroll event retries it.
            }
        }

        /// Jumps the PDFView to the given page index (called from the
        /// thumbnail sidebar via `model.goToPage(_:)`).
        func goToPage(_ index: Int) {
            guard let pdfView, let document = pdfView.document,
                  let page = document.page(at: index)
            else { return }
            pdfView.go(to: page)
        }

        /// One-shot "native page size" fit (Session 8): opens the document at
        /// 100% scale (`scaleFactor = 1.0`) — the page's true point size —
        /// rather than a fit-to-width column. This reads well for a
        /// US-Letter/A4 page on a laptop, and PDFKit automatically centers a
        /// page that's narrower than the view, so this yields natural
        /// margins on wide windows for free. Runs at most once per document
        /// load — after that, whatever scale the user picks (by pinch/zoom
        /// or the zoom controls) is left alone.
        func applyInitialZoomIfNeeded() {
            guard !didApplyInitialZoom,
                  let pdfView,
                  let document = pdfView.document,
                  document.pageCount > 0
            else { return }

            // Bounds may still be zero if this is racing SwiftUI's layout
            // pass; try again on the next run loop turn rather than
            // committing before the view has a real size.
            guard pdfView.bounds.width > 0, pdfView.bounds.height > 0 else {
                DispatchQueue.main.async { [weak self] in
                    self?.applyInitialZoomIfNeeded()
                }
                return
            }

            pdfView.scaleFactor = 1.0
            didApplyInitialZoom = true

            // Session 8: consume any pending cross-window jump (e.g. from
            // clicking a highlight reference in the notes window, which set
            // this before opening a possibly-fresh reader window) now that
            // the initial zoom/layout has settled, so the resulting scroll
            // position sticks.
            if let requestedPage = PendingReaderJump.take(paperId: paperId),
               let page = document.page(at: min(max(requestedPage, 0), document.pageCount - 1)) {
                pdfView.go(to: page)
            } else if let savedPage = paper.lastPage {
                let pageIndex = min(max(savedPage, 0), document.pageCount - 1)
                if let page = document.page(at: pageIndex) {
                    let destination = PDFDestination(
                        page: page,
                        at: CGPoint(x: 0, y: paper.lastScrollOffset ?? 0)
                    )
                    pdfView.go(to: destination)
                }
            }
        }

        /// Handles a request (from the notes window) to jump this paper's reader to a page.
        @objc func jumpRequested(_ note: Notification) {
            guard let info = note.userInfo,
                  let pid = info["paperId"] as? String, pid == paperId,
                  let pageIndex = info["pageIndex"] as? Int,
                  let pdfView, let document = pdfView.document,
                  let page = document.page(at: pageIndex)
            else { return }
            pdfView.go(to: page)
            pdfView.window?.makeKeyAndOrderFront(nil)
        }

        /// Persists a `Highlight` row (one per page the selection touches) for
        /// the current selection in `color`, then redraws from the DB.
        func addHighlight(_ color: HighlightColor) {
            guard let pdfView,
                  let document = pdfView.document,
                  let selection = pdfView.currentSelection,
                  let text = selection.string, !text.isEmpty
            else { return }

            let spans = HighlightRenderer.spans(from: selection, in: document)
            guard !spans.isEmpty else { return }

            let rows = spans.map { span in
                Highlight(
                    paperId: paperId,
                    page: span.pageIndex,
                    boundingBoxes: BoundingBoxCodec.encode(span.rects),
                    color: color.rawValue,
                    selectedText: span.text
                )
            }

            try? repository.insertHighlights(rows)
            pdfView.clearSelection()
            model.hasSelection = false
            rehydrate()
        }

        private func renderProposals(forPage pageIndex: Int) {
            removeDrawnProposalAnnotations()
            guard let document = pdfView?.document,
                  let page = document.page(at: pageIndex)
            else {
                model.keyIdeaProposals = []
                return
            }

            let proposals = proposalsByPage[pageIndex] ?? []
            for proposal in proposals {
                proposedAnnotations[proposal.id] = HighlightRenderer.addProposalAnnotations(
                    rects: proposal.rects,
                    on: page
                )
            }
            model.keyIdeaProposals = proposals
        }

        private func removeDrawnProposalAnnotations() {
            proposedAnnotations.values.forEach(HighlightRenderer.removeAnnotations)
            proposedAnnotations.removeAll()
            model.keyIdeaProposals.removeAll()
        }

        func autoSuggestCurrentPageIfNeeded() {
            autoSuggestTask?.cancel()
            autoSuggestTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self,
                      self.model.isAIAssistModeActive
                else { return }
                self.fetchOrRenderCurrentPage()
            }
        }

        func fetchOrRenderCurrentPage() {
            guard model.isAIAssistModeActive else { return }
            guard let pdfView, let document = pdfView.document,
                  let page = pdfView.currentPage, let text = page.string
            else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return }

            autoSuggestTask?.cancel()
            autoSuggestTask = nil
            if fetchedPages.contains(pageIndex) {
                renderProposals(forPage: pageIndex)
                return
            }
            guard !inFlightPages.contains(pageIndex) else { return }

            inFlightPages.insert(pageIndex)
            let generation = proposalGeneration
            model.isSuggestingKeyIdeas = true
            model.keyIdeaError = nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.proposalGeneration == generation {
                        self.inFlightPages.remove(pageIndex)
                        self.updateSuggestionLoadingState()
                    }
                }
                do {
                    let sentences = try await self.keyIdeaService.suggestKeyIdeas(pageText: text)
                    guard self.proposalGeneration == generation,
                          self.model.isAIAssistModeActive,
                          self.pdfView?.currentPage === page
                    else { return }
                    var proposals: [KeyIdeaProposal] = []
                    for sentence in sentences {
                        let rects = HighlightRenderer.locate(sentence: sentence, on: page)
                        guard !rects.isEmpty else { continue }
                        let proposal = KeyIdeaProposal(
                            id: UUID(), sentence: sentence, pageIndex: pageIndex, rects: rects
                        )
                        proposals.append(proposal)
                    }
                    self.proposalsByPage[pageIndex] = proposals
                    self.fetchedPages.insert(pageIndex)
                    self.renderProposals(forPage: pageIndex)
                } catch GeminiClientError.missingAPIKey {
                    if self.proposalGeneration == generation,
                       self.pdfView?.currentPage === page {
                        self.model.keyIdeaError = "No Gemini key — add one in Settings"
                    }
                } catch {
                    if self.proposalGeneration == generation,
                       self.pdfView?.currentPage === page {
                        self.model.keyIdeaError = "Couldn’t suggest key ideas. Please try again."
                    }
                }
            }
        }

        private func updateSuggestionLoadingState() {
            guard let pdfView, let document = pdfView.document,
                  let page = pdfView.currentPage
            else {
                model.isSuggestingKeyIdeas = false
                return
            }
            model.isSuggestingKeyIdeas = inFlightPages.contains(document.index(for: page))
        }

        func acceptKeyIdea(_ id: UUID) {
            guard let proposal = model.keyIdeaProposals.first(where: { $0.id == id }) else { return }
            let row = Highlight(
                paperId: paperId, page: proposal.pageIndex,
                boundingBoxes: BoundingBoxCodec.encode(proposal.rects),
                color: HighlightColor.yellow.rawValue, selectedText: proposal.sentence
            )
            try? repository.insertHighlights([row])
            removeProposal(id)
            rehydrate()
        }

        func acceptAllKeyIdeas() {
            guard let pageIndex = model.keyIdeaProposals.first?.pageIndex else { return }
            let rows = model.keyIdeaProposals.map { proposal in
                Highlight(
                    paperId: paperId, page: proposal.pageIndex,
                    boundingBoxes: BoundingBoxCodec.encode(proposal.rects),
                    color: HighlightColor.yellow.rawValue, selectedText: proposal.sentence
                )
            }
            guard !rows.isEmpty else { return }
            try? repository.insertHighlights(rows)
            proposalsByPage[pageIndex] = []
            renderProposals(forPage: pageIndex)
            rehydrate()
        }

        func dismissKeyIdea(_ id: UUID) { removeProposal(id) }

        private func removeProposal(_ id: UUID) {
            HighlightRenderer.removeAnnotations(proposedAnnotations[id] ?? [])
            proposedAnnotations[id] = nil
            let pageIndex = model.currentPageIndex
            proposalsByPage[pageIndex]?.removeAll { $0.id == id }
            model.keyIdeaProposals.removeAll { $0.id == id }
        }

        func clearKeyIdeaProposals() {
            autoSuggestTask?.cancel()
            autoSuggestTask = nil
            proposalGeneration += 1
            proposalsByPage.removeAll()
            fetchedPages.removeAll()
            inFlightPages.removeAll()
            removeDrawnProposalAnnotations()
            model.isSuggestingKeyIdeas = false
            model.keyIdeaError = nil
        }

        /// Removes every tracked annotation and redraws all of this paper's
        /// highlights (and comment-dots) fresh from the database.
        func rehydrate() {
            guard let pdfView, let document = pdfView.document else { return }

            HighlightRenderer.removeAnnotations(tracked)
            tracked.removeAll()
            annotationToId.removeAll()

            let highlights = (try? repository.highlights(forPaper: paperId)) ?? []
            let commented = (try? repository.commentedHighlightIds(forPaper: paperId)) ?? []

            for highlight in highlights {
                let added = HighlightRenderer.addAnnotations(
                    for: highlight,
                    hasComment: commented.contains(highlight.id),
                    to: document
                )
                for annotation in added {
                    annotationToId[annotation] = highlight.id
                }
                tracked.append(contentsOf: added)
            }
        }

        func handleAnnotationClick(_ annotation: PDFAnnotation, page: PDFPage) -> Bool {
            guard let highlightId = annotationToId[annotation], let pdfView else { return false }
            lastOpenedHighlightId = highlightId
            showCommentPopover(highlightId: highlightId, annotation: annotation, page: page, in: pdfView)
            return true
        }

        /// Deletes a highlight (its comment cascades away via the FK) and redraws
        /// from the database.
        func deleteHighlight(_ id: String) {
            try? repository.deleteHighlight(id: id)
            popover?.close()
            if lastOpenedHighlightId == id { lastOpenedHighlightId = nil }
            rehydrate()
        }

        func showCommentPopover(highlightId: String, annotation: PDFAnnotation, page: PDFPage, in pdfView: PDFView) {
            popover?.close()

            let existing: Comment? = (try? repository.comment(forHighlight: highlightId)) ?? nil

            let editor = CommentEditorView(
                initialText: existing?.body ?? "",
                hasExistingComment: existing != nil,
                onSave: { [weak self] body in
                    guard let self else { return }
                    _ = try? self.repository.upsertComment(highlightId: highlightId, paperId: self.paperId, body: body)
                    self.popover?.close()
                    self.rehydrate()
                },
                onCancel: { [weak self] in
                    self?.popover?.close()
                },
                onDelete: existing == nil ? nil : { [weak self] in
                    guard let self else { return }

                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Delete this comment?"
                    alert.informativeText = "This leaves the highlight; only the comment is removed."
                    alert.addButton(withTitle: "Delete")
                    alert.buttons.first?.hasDestructiveAction = true
                    alert.addButton(withTitle: "Cancel")

                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    do {
                        try self.repository.deleteComment(forHighlight: highlightId)
                        self.popover?.close()
                        self.rehydrate()
                    } catch {
                        // Keep the editor open if deletion fails so the user's
                        // comment is not made to appear deleted when it is not.
                    }
                }
            )

            let pop = NSPopover()
            pop.behavior = .transient
            // SwiftUI updates the hosting view's intrinsic size on every
            // resize-handle drag tick. Popover animation otherwise queues
            // animated size/re-anchoring updates and makes the drag stutter.
            pop.animates = false
            pop.contentSize = CGSize(width: 320, height: 240)
            pop.contentViewController = NSHostingController(rootView: editor)

            let rectInView = pdfView.convert(annotation.bounds, from: page)
            pop.show(relativeTo: rectInView, of: pdfView, preferredEdge: .maxY)
            self.popover = pop

            // Ensure the popover's window becomes key so the TextEditor can
            // receive keyboard input immediately.
            DispatchQueue.main.async {
                pop.contentViewController?.view.window?.makeKey()
            }
        }

        // MARK: - Quick-action context providers (Session 7 Part C)

        /// The current PDF text selection, trimmed; nil if there is none.
        func currentSelectionText() -> String? {
            guard let text = pdfView?.currentSelection?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// The full text of the page currently in view (used both as
        /// "surrounding context" for a selection and as the summarization
        /// fallback when there's no selection). Falls back to the first page
        /// of the current selection if `currentPage` hasn't been set yet.
        func currentPageText() -> String? {
            let page = pdfView?.currentPage ?? pdfView?.currentSelection?.pages.first
            guard let text = page?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        /// The last-opened highlight's text + comment for the "Explain this
        /// highlight" quick action. Falls back to the current text selection
        /// (treated as the highlight text) if no highlight has been opened,
        /// so a user who has just made a fresh selection isn't blocked.
        func openHighlightForQuickAction() -> (text: String, comment: String?)? {
            if let id = lastOpenedHighlightId, let highlight = try? repository.highlight(id: id) {
                let comment = try? repository.comment(forHighlight: id)
                return (text: highlight.selectedText, comment: comment?.body)
            }
            if let selection = currentSelectionText() {
                return (text: selection, comment: nil)
            }
            return nil
        }
    }
}
