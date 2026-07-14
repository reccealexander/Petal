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
    @StateObject private var bookmarkStore: PageBookmarkStore
    @State private var isTagPopoverPresented = false
    @State private var isKeyIdeaPopoverPresented = false
    @State private var readerWindow: NSWindow?
    @State private var savedWindowAppearance: WindowAppearance?
    @State private var readingStatus: ReadingStatus
    @State private var isHighlightTaxonomyPresented = false
    @State private var isFocusToolbarExpanded = false
    @State private var focusToolbarOffset: CGSize = .zero
    @State private var hasNote = false
    @State private var aiPanelResizeStartWidth: Double?
    @State private var draggingPanelWidth: Double?
    @StateObject private var accent = AccentColorProvider()
    @GestureState private var focusToolbarDragOffset: CGSize = .zero
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var snapController: WindowSnapController
    @EnvironmentObject private var focus: FocusModeController
    @EnvironmentObject private var appearance: AppearanceManager
    private let chapters: [PDFChapterEntry]

    init(paper: Paper, database: DatabaseManager, isStandaloneWindow: Bool = true) {
        self.paper = paper
        self.database = database
        self.isStandaloneWindow = isStandaloneWindow
        _readingStatus = State(initialValue: ReadingStatus(rawValueOrUnread: paper.readingStatus))
        let document = PDFDocument(url: PDFImportService.fileURL(for: paper, in: database.papersDirectory))
        chapters = Self.chapterEntries(in: document)
        _thumbnailProvider = StateObject(wrappedValue: PageThumbnailProvider(
            paperId: paper.id,
            document: document,
            papersDirectory: database.papersDirectory
        ))
        _tagPopoverModel = StateObject(wrappedValue: ReaderTagPopoverModel(paper: paper, database: database))
        _bookmarkStore = StateObject(wrappedValue: PageBookmarkStore(
            paperId: paper.id,
            repository: PageBookmarkRepository(database: database)
        ))
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
            if !focus.isActive && model.isThumbnailSidebarVisible && thumbnailProvider.pageCount > 0 {
                PageThumbnailSidebar(
                    provider: thumbnailProvider,
                    model: model,
                    bookmarkStore: bookmarkStore,
                    chapters: chapters
                )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            PDFKitWrapper(
                url: PDFImportService.fileURL(for: paper, in: database.papersDirectory),
                paper: paper,
                database: database,
                model: model,
                isFocusModeActive: focus.isActive,
                onNextChapter: goToNextChapter,
                onPreviousChapter: goToPreviousChapter
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Session 6 Part B: Claude Q&A side panel. Implemented as a
            // conditional pane in this HStack (see judgment-call note on
            // ClaudePanelView) rather than a literal NSSplitViewController
            // third pane — it slides in from the trailing edge when toggled.
            if !focus.isActive && model.isClaudePanelVisible {
                aiPanelResizeHandle
                ClaudePanelView(
                    paper: paper,
                    database: database,
                    readerSource: readerQuickActionSource,
                    initialNotebookScope: model.chatScopeIsNotebook,
                    onScopeChange: { model.chatScopeIsNotebook = $0 }
                )
                    .frame(width: livePanelWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
            .overlay(alignment: .topTrailing) {
                if focus.isActive {
                    focusToolbar
                        .padding(16)
                        .offset(
                            x: focusToolbarOffset.width + focusToolbarDragOffset.width,
                            y: focusToolbarOffset.height + focusToolbarDragOffset.height
                        )
                        .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isThumbnailSidebarVisible)
            .animation(.easeInOut(duration: 0.2), value: model.isClaudePanelVisible)
            .navigationTitle(paper.title ?? "Untitled")
            .onAppear {
                updateLastOpened()
                advanceReadingStatusIfNeeded()
                bookmarkStore.load()
                refreshHasNote()
            }
            // Session 9 Part A (best effort, not GUI-verified): standalone
            // reader windows register with CompareCoordinator so drag-to-snap
            // can detect two of them being dragged edge-to-edge. Panes
            // embedded in a CompareReaderView (isStandaloneWindow == false)
            // never register — only real standalone windows are snap-able.
            .background(
                Group {
                    if isStandaloneWindow {
                        WindowAccessor { window in
                            readerWindow = window
                            snapController.register(ref: .reader(paperId: paper.id), window: window)
                            updateWindowAppearance(for: window)
                        }
                    }
                }
            )
            .onDisappear {
                model.saveResumePositionNow()
                if focus.isActive, readerWindow != nil {
                    focus.exit()
                }
                if isStandaloneWindow {
                    snapController.unregister(ref: .reader(paperId: paper.id))
                }
            }
            .onChange(of: focus.isActive) { _, isActive in
                if isActive {
                    isFocusToolbarExpanded = false
                    focusToolbarOffset = .zero
                }
                if let readerWindow { updateWindowAppearance(for: readerWindow) }
            }
            .onChange(of: model.isAIAssistModeActive) { _, isActive in
                if isActive {
                    model.suggestKeyIdeas()
                } else {
                    isKeyIdeaPopoverPresented = false
                    model.clearKeyIdeaProposals()
                }
            }
            .onExitCommand {
                if focus.isActive { focus.exit() }
            }
            .toolbar {
                if isStandaloneWindow && !focus.isActive {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if focus.isActive {
                                focus.exit()
                            } else {
                                focus.enter(focusedWindow: readerWindow)
                            }
                        } label: {
                            Label("Focus", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .help("Enter Focus mode")
                    }
                }

                if !focus.isActive {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(ReadingStatus.allCases) { status in
                                Button {
                                    setReadingStatus(status)
                                } label: {
                                    Label(status.label, systemImage: status.symbol)
                                }
                            }
                        } label: {
                            Label(readingStatus.label, systemImage: readingStatus.symbol)
                        }
                        .help("Reading status: \(readingStatus.label)")
                    }

                    ToolbarItem(placement: .navigation) {
                        Button {
                            model.isThumbnailSidebarVisible.toggle()
                        } label: {
                            Label("Reader Sidebar", systemImage: "sidebar.left")
                        }
                        .help("Show or hide the reader sidebar")
                    }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(value: NotesWindowID(paperId: paper.id))
                    } label: {
                        Label("Notes", systemImage: "note.text")
                            .foregroundStyle(hasNote ? accent.color : Color.secondary)
                    }
                    .help("Open notes for this paper")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isHighlightTaxonomyPresented = true
                    } label: {
                        Label("Highlights", systemImage: "list.bullet.rectangle")
                    }
                    .help("Highlights")
                    .sheet(isPresented: $isHighlightTaxonomyPresented) {
                        HighlightTaxonomyView(paper: paper, database: database) { page in
                            model.goToPage(page)
                        }
                    }
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
                                    snapController.closeStandaloneWindowIfOpen(paperId: other.id)
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
                        Label("Ask AI", systemImage: "sparkles")
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Ask AI about this paper")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isAIAssistModeActive.toggle()
                    } label: {
                        Label("AI Notes", systemImage: model.isAIAssistModeActive
                              ? "wand.and.stars.inverse" : "wand.and.stars")
                            .foregroundStyle(model.isAIAssistModeActive ? Color.accentColor : Color.primary)
                    }
                    .help(model.hasGeminiKey()
                          ? "Toggle AI-assisted note-taking"
                          : "Add a Gemini API key in Settings to use AI Notes")
                    .disabled(!model.hasGeminiKey())
                }

                if model.isAIAssistModeActive {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isKeyIdeaPopoverPresented = true
                        } label: {
                            Label("Review key ideas", systemImage: "text.badge.star")
                        }
                        .help("Review key ideas on this page")
                        .popover(isPresented: $isKeyIdeaPopoverPresented) {
                            KeyIdeaSuggestionPopover(model: model)
                        }
                    }
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
    }

    /// A wider hit target around a one-pixel separator. Since the panel sits
    /// on the trailing edge, dragging right reduces its width.
    private var aiPanelResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .frame(width: 6)
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if aiPanelResizeStartWidth == nil {
                        aiPanelResizeStartWidth = appearance.aiPanelWidth
                    }
                    guard let startWidth = aiPanelResizeStartWidth else { return }
                    draggingPanelWidth = min(max(startWidth - value.translation.width, 280), 620)
                }
                .onEnded { _ in
                    if let draggingPanelWidth {
                        appearance.aiPanelWidth = draggingPanelWidth
                    }
                    draggingPanelWidth = nil
                    aiPanelResizeStartWidth = nil
                }
        )
    }

    private var livePanelWidth: Double {
        draggingPanelWidth ?? appearance.aiPanelWidth
    }

    /// The sole piece of reader chrome retained in Focus mode. It starts as a
    /// small disclosure button at the top-trailing corner and uses the same
    /// Notes, highlight-browser, and add-highlight actions as the main toolbar.
    private var focusToolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isFocusToolbarExpanded.toggle()
                }
            } label: {
                Image(systemName: isFocusToolbarExpanded ? "chevron.right" : "slider.horizontal.3")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help(isFocusToolbarExpanded ? "Collapse Focus toolbar" : "Expand Focus toolbar")

            if isFocusToolbarExpanded {
                Divider()
                    .frame(height: 20)

                Button {
                    openWindow(value: NotesWindowID(paperId: paper.id))
                } label: {
                    Image(systemName: "note.text")
                        .foregroundStyle(hasNote ? accent.color : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Open notes for this paper")

                Button {
                    openWindow(value: ChatWindowID(
                        paperId: paper.id,
                        isNotebookScope: model.chatScopeIsNotebook
                    ))
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.plain)
                .help("Open chat")

                Button {
                    isHighlightTaxonomyPresented = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .buttonStyle(.plain)
                .help("Highlights")

                ForEach(HighlightColor.allCases) { color in
                    Button {
                        model.addHighlight(color)
                    } label: {
                        Circle().fill(Color(nsColor: color.nsColor))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Highlight \(color.displayName)")
                    .disabled(!model.hasSelection)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture()
                .updating($focusToolbarDragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    focusToolbarOffset.width += value.translation.width
                    focusToolbarOffset.height += value.translation.height
                }
        )
        .sheet(isPresented: $isHighlightTaxonomyPresented) {
            HighlightTaxonomyView(paper: paper, database: database) { page in
                model.goToPage(page)
            }
        }
    }

    private func refreshHasNote() {
        hasNote = ((try? NoteRepository(database: database).primaryNote(forPaper: paper.id)) ?? nil) != nil
    }

    private func goToNextChapter() {
        guard let chapter = chapters.first(where: { $0.pageIndex > model.currentPageIndex }) else { return }
        model.goToPage(chapter.pageIndex)
    }

    private func goToPreviousChapter() {
        guard let chapter = chapters.last(where: { $0.pageIndex < model.currentPageIndex }) else { return }
        model.goToPage(chapter.pageIndex)
    }

    /// Extracts value-only top-level outline data while the PDF is being
    /// opened. PDFKit objects are not retained as reader UI state.
    private static func chapterEntries(in document: PDFDocument?) -> [PDFChapterEntry] {
        guard let document, let root = document.outlineRoot else { return [] }

        return (0..<root.numberOfChildren).compactMap { childIndex in
            guard
                let child = root.child(at: childIndex),
                let page = child.destination?.page,
                let rawLabel = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawLabel.isEmpty
            else { return nil }

            let pageIndex = document.index(for: page)
            guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }
            return PDFChapterEntry(id: childIndex, label: rawLabel, pageIndex: pageIndex)
        }
    }

    private func updateWindowAppearance(for window: NSWindow) {
        if focus.isActive {
            if savedWindowAppearance == nil {
                savedWindowAppearance = WindowAppearance(window: window)
            }
            window.toolbar?.isVisible = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        } else if let savedWindowAppearance {
            savedWindowAppearance.restore(to: window)
            self.savedWindowAppearance = nil
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

    private func advanceReadingStatusIfNeeded() {
        guard paper.readingStatus == ReadingStatus.unread.rawValue else { return }
        setReadingStatus(.inProgress)
    }

    private func setReadingStatus(_ status: ReadingStatus) {
        guard (try? NotebookRepository(database: database).setReadingStatus(
            paperId: paper.id,
            status: status.rawValue
        )) != nil else { return }
        readingStatus = status
    }
}

private struct KeyIdeaSuggestionPopover: View {
    @ObservedObject var model: PDFReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Key ideas")
                    .font(.headline)
                Spacer()
                if model.keyIdeaProposals.count >= 2 {
                    Button("Accept all") { model.acceptAllKeyIdeas() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField(
                        "What should count as a key insight? (optional)",
                        text: $model.keyIdeaInstruction
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.regenerateKeyIdeas() }
                    Button("Apply") { model.regenerateKeyIdeas() }
                }
                Text("e.g. “the methodology”, “limitations”. Applies to this and following pages.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.isSuggestingKeyIdeas {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding key ideas…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.keyIdeaError {
                Text(error)
                    .foregroundStyle(.red)
            } else if model.keyIdeaProposals.isEmpty {
                ContentUnavailableView(
                    "No key ideas found on this page",
                    systemImage: "text.badge.xmark"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Click a highlight to accept it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.keyIdeaProposals) { proposal in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(proposal.sentence)
                                        .lineLimit(3)
                                    Button("Dismiss", role: .cancel) {
                                        model.dismissKeyIdea(proposal.id)
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding()
        .frame(width: 390)
    }
}

@MainActor
private struct WindowAppearance {
    let toolbarIsVisible: Bool?
    let titlebarAppearsTransparent: Bool
    let titleVisibility: NSWindow.TitleVisibility
    let isOpaque: Bool
    let backgroundColor: NSColor
    let hasShadow: Bool
    let closeIsHidden: Bool
    let miniaturizeIsHidden: Bool
    let zoomIsHidden: Bool

    init(window: NSWindow) {
        toolbarIsVisible = window.toolbar?.isVisible
        titlebarAppearsTransparent = window.titlebarAppearsTransparent
        titleVisibility = window.titleVisibility
        isOpaque = window.isOpaque
        backgroundColor = window.backgroundColor
        hasShadow = window.hasShadow
        closeIsHidden = window.standardWindowButton(.closeButton)?.isHidden ?? false
        miniaturizeIsHidden = window.standardWindowButton(.miniaturizeButton)?.isHidden ?? false
        zoomIsHidden = window.standardWindowButton(.zoomButton)?.isHidden ?? false
    }

    func restore(to window: NSWindow) {
        if let toolbarIsVisible { window.toolbar?.isVisible = toolbarIsVisible }
        window.titlebarAppearsTransparent = titlebarAppearsTransparent
        window.titleVisibility = titleVisibility
        window.isOpaque = isOpaque
        window.backgroundColor = backgroundColor
        window.hasShadow = hasShadow
        window.standardWindowButton(.closeButton)?.isHidden = closeIsHidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = miniaturizeIsHidden
        window.standardWindowButton(.zoomButton)?.isHidden = zoomIsHidden
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
