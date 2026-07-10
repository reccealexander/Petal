import SwiftUI
import PDFKit
import GRDB
import PaperReaderCore

/// Full-window PDF reading surface for a single `Paper` (spec §3 Phase 1).
///
/// Resolves the paper's on-disk PDF via `PDFImportService.fileURL(for:in:)` and
/// hands it to `PDFKitWrapper` for rendering. Records that the paper was opened
/// by stamping `last_opened_at` when the view appears.
///
/// Session 6 Part A adds a collapsible left-side page-thumbnail sidebar
/// (`PageThumbnailSidebar`), backed by a per-paper `PageThumbnailProvider`
/// that caches generated thumbnails to disk so reopening is instant.
///
/// Session 9 Part A adds an `isStandaloneWindow` flag: true when this view is
/// the sole content of its own reader `WindowGroup` (the normal case), false
/// when it's embedded as one pane of a `CompareReaderView`. The flag gates
/// two things that only make sense for a real standalone window: registering
/// with `CompareCoordinator` for drag-to-snap, and closing "this window" when
/// the user picks a paper from the "Compare side-by-side" menu.
struct PDFReaderView: View {
    let paper: Paper
    let database: DatabaseManager
    let isStandaloneWindow: Bool

    @StateObject private var model = PDFReaderModel()
    @StateObject private var thumbnailProvider: PageThumbnailProvider
    @StateObject private var tagPopoverModel: ReaderTagPopoverModel
    @State private var isTagPopoverPresented = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var compareCoordinator: CompareCoordinator

    init(paper: Paper, database: DatabaseManager, isStandaloneWindow: Bool = true) {
        self.paper = paper
        self.database = database
        self.isStandaloneWindow = isStandaloneWindow
        let document = PDFDocument(url: PDFImportService.fileURL(for: paper, in: database.papersDirectory))
        _thumbnailProvider = StateObject(wrappedValue: PageThumbnailProvider(
            paperId: paper.id,
            document: document,
            papersDirectory: database.papersDirectory
        ))
        _tagPopoverModel = StateObject(wrappedValue: ReaderTagPopoverModel(paper: paper, database: database))
    }

    /// Every other imported paper, for the "Compare side-by-side" menu.
    /// Excludes the current paper; empty (and thus the menu disabled) if
    /// nothing else has been imported.
    private var otherPapers: [Paper] {
        let repo = NotebookRepository(database: database)
        return ((try? repo.allPapers()) ?? []).filter { $0.id != paper.id }
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.isThumbnailSidebarVisible && thumbnailProvider.pageCount > 0 {
                PageThumbnailSidebar(provider: thumbnailProvider, model: model)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            PDFKitWrapper(
                url: PDFImportService.fileURL(for: paper, in: database.papersDirectory),
                paper: paper,
                database: database,
                model: model
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Session 6 Part B: Claude Q&A side panel. Implemented as a
            // conditional pane in this HStack (see judgment-call note on
            // ClaudePanelView) rather than a literal NSSplitViewController
            // third pane — it slides in from the trailing edge when toggled.
            if model.isClaudePanelVisible {
                Divider()
                ClaudePanelView(paper: paper, database: database, readerSource: readerQuickActionSource)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
            .animation(.easeInOut(duration: 0.2), value: model.isThumbnailSidebarVisible)
            .animation(.easeInOut(duration: 0.2), value: model.isClaudePanelVisible)
            .navigationTitle(paper.title ?? "Untitled")
            .onAppear { updateLastOpened() }
            // Session 9 Part A (best effort, not GUI-verified): standalone
            // reader windows register with CompareCoordinator so drag-to-snap
            // can detect two of them being dragged edge-to-edge. Panes
            // embedded in a CompareReaderView (isStandaloneWindow == false)
            // never register — only real standalone windows are snap-able.
            .background(
                Group {
                    if isStandaloneWindow {
                        WindowAccessor { window in
                            compareCoordinator.registerReaderWindow(paperId: paper.id, window: window)
                        }
                    }
                }
            )
            .onDisappear {
                if isStandaloneWindow {
                    compareCoordinator.unregisterReaderWindow(paperId: paper.id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.isThumbnailSidebarVisible.toggle()
                    } label: {
                        Label("Page Thumbnails", systemImage: "sidebar.left")
                    }
                    .help("Show or hide page thumbnails")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(value: NotesWindowID(paperId: paper.id))
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .help("Open notes for this paper")
                }

                // Session 9 Part A: explicit, reliable trigger for
                // side-by-side compare (the REQUIRED path — drag-to-snap in
                // CompareCoordinator is best-effort on top of this). Lists
                // every other imported paper; picking one opens a
                // CompareReaderView pair window and closes this standalone
                // window (dismiss() is a no-op when embedded as a compare
                // pane, so this is safe to leave in the toolbar there too).
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if otherPapers.isEmpty {
                            Text("No other papers imported")
                        } else {
                            ForEach(otherPapers) { other in
                                Button(other.title ?? "Untitled") {
                                    openWindow(value: ComparePairID(leftPaperId: paper.id, rightPaperId: other.id))
                                    compareCoordinator.closeStandaloneWindowIfOpen(paperId: other.id)
                                    if isStandaloneWindow {
                                        dismiss()
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Compare side-by-side", systemImage: "rectangle.split.2x1")
                    }
                    .help("Compare with another paper side by side")
                    .disabled(otherPapers.isEmpty)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isClaudePanelVisible.toggle()
                    } label: {
                        Label("Ask Gemini", systemImage: "sparkles")
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Ask Gemini about this paper")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(HighlightColor.allCases) { color in
                        Button {
                            model.addHighlight(color)
                        } label: {
                            Circle().fill(Color(nsColor: color.nsColor))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                        }
                        .help("Highlight \(color.displayName)")
                        .disabled(!model.hasSelection)
                    }
                }

                // Session 7 Part A, Feature 1: tag button with AI-recommended
                // tag suggestions, mirroring the home-view card's tag editor
                // but adding a separate "Suggested" section.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tagPopoverModel.load()
                        isTagPopoverPresented = true
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                    .help("Tags")
                    .popover(isPresented: $isTagPopoverPresented) {
                        ReaderTagPopoverView(model: tagPopoverModel)
                    }
                }
            }
    }

    /// The Claude panel's quick-action buttons (Session 7 Part C) read the
    /// live PDF selection/page/highlight through `model`'s provider closures
    /// (set by `PDFKitWrapper.Coordinator`) rather than touching PDFKit
    /// directly — this just adapts those into the small closure bundle
    /// `ClaudePanelView` expects.
    private var readerQuickActionSource: ReaderQuickActionSource {
        ReaderQuickActionSource(
            selection: { model.selectionText() },
            surrounding: { model.surroundingText() },
            pageText: { model.pageText() },
            openHighlight: { model.openHighlight() }
        )
    }

    /// Stamps `last_opened_at` on the paper's row with the current time.
    private func updateLastOpened() {
        try? database.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE paper SET last_opened_at = ? WHERE id = ?",
                arguments: [Date(), paper.id]
            )
        }
    }
}

/// Content of the reader toolbar's tag popover (Session 7 Part A, Feature 1):
/// the paper's existing assigned tags (removable), plus a clearly separated
/// "Suggested" section of AI-recommended tags the user can click to accept.
/// Mirrors the visual style of the home-view card's tag editor
/// (`PaperCardView.tagEditorPopover`) — capsule chips laid out with
/// `FlowLayout` — while keeping all DB/network logic in `ReaderTagPopoverModel`.
private struct ReaderTagPopoverView: View {
    @ObservedObject var model: ReaderTagPopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if model.assignedTags.isEmpty {
                    Text("No tags yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(model.assignedTags) { tag in
                            HStack(spacing: 4) {
                                Text(tag.name)
                                    .font(.caption)
                                Button {
                                    model.remove(tag)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                if !model.hasAPIKey {
                    Text("Add an API key in Preferences to generate tag suggestions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating suggestions…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.suggestions.isEmpty {
                    Text(model.errorMessage ?? "No suggestions right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowLayout(spacing: 4) {
                        ForEach(model.suggestions, id: \.self) { name in
                            Button {
                                model.accept(name)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.caption2)
                                    Text(name)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260)
        .task {
            await model.refreshSuggestions()
        }
    }
}
