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

    private var pendingDeleteHighlightId: String?

    override func mouseDown(with event: NSEvent) {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(paperId: paper.id, model: model, repository: HighlightRepository(database: database))
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = AnnotatablePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)

        let coord = context.coordinator
        coord.pdfView = pdfView
        pdfView.onAnnotationClick = { [weak coord] annotation, page in
            coord?.handleAnnotationClick(annotation, page: page) ?? false
        }
        pdfView.highlightId = { [weak coord] annotation in coord?.annotationToId[annotation] }
        pdfView.onDeleteHighlight = { [weak coord] id in coord?.deleteHighlight(id) }
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.jumpRequested(_:)),
            name: .readerJumpToHighlight, object: nil)
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: pdfView)
        model.performAddHighlight = { [weak coord] color in coord?.addHighlight(color) }
        model.performGoToPage = { [weak coord] index in coord?.goToPage(index) }
        coord.rehydrate()
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
            context.coordinator.rehydrate()
        }
    }

    /// Owns the PDFKit-facing state that has no place in SwiftUI: the live
    /// mapping from tracked `PDFAnnotation`s back to `Highlight` ids, and the
    /// comment popover. `@MainActor` because it touches `model` (an
    /// `ObservableObject`) and AppKit UI directly.
    @MainActor
    final class Coordinator: NSObject {
        let paperId: String
        let model: PDFReaderModel
        let repository: HighlightRepository
        weak var pdfView: AnnotatablePDFView?
        var tracked: [PDFAnnotation] = []
        var annotationToId: [PDFAnnotation: String] = [:]
        var popover: NSPopover?

        init(paperId: String, model: PDFReaderModel, repository: HighlightRepository) {
            self.paperId = paperId
            self.model = model
            self.repository = repository
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
            model.currentPageIndex = document.index(for: page)
        }

        /// Jumps the PDFView to the given page index (called from the
        /// thumbnail sidebar via `model.goToPage(_:)`).
        func goToPage(_ index: Int) {
            guard let pdfView, let document = pdfView.document,
                  let page = document.page(at: index)
            else { return }
            pdfView.go(to: page)
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
            showCommentPopover(highlightId: highlightId, annotation: annotation, page: page, in: pdfView)
            return true
        }

        /// Deletes a highlight (its comment cascades away via the FK) and redraws
        /// from the database.
        func deleteHighlight(_ id: String) {
            try? repository.deleteHighlight(id: id)
            popover?.close()
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
                onDelete: nil
            )

            let pop = NSPopover()
            pop.behavior = .transient
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
    }
}
