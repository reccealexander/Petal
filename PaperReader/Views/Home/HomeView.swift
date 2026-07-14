import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperReaderCore
import GRDB

/// The app's home screen (spec Session 5 Part A): a notebook sidebar (with tag
/// filters) next to a searchable grid of papers. Tapping a card opens the paper
/// in its own reader window.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceManager

    var body: some View {
        Group {
            if let db = appState.database {
                LibraryContentView(database: db)
            } else {
                databaseErrorView
            }
        }
        .background(MainWindowTransparencyBridge(alpha: appearance.chromeAlpha))
    }

    @ViewBuilder
    private var databaseErrorView: some View {
        VStack(spacing: 8) {
            Label("Database unavailable", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.headline)
            if case let .failed(message) = appState.databaseStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keeps the main window's chrome separate from the fully opaque SwiftUI card
/// content. This bridge is attached only to `HomeView`, so secondary windows
/// and Settings are never modified.
private struct MainWindowTransparencyBridge: NSViewRepresentable {
    let alpha: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainWindowTransparencyApplier.apply(alpha: alpha, to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        MainWindowTransparencyApplier.apply(alpha: alpha, to: window)
    }
}

@MainActor
private enum MainWindowTransparencyApplier {
    private static let chromeIdentifier = NSUserInterfaceItemIdentifier("PaperReader.MainWindowChrome")

    static func apply(alpha: CGFloat, to window: NSWindow) {
        let alpha = min(max(alpha, 0), 1)

        if alpha >= 1 {
            // Remove any chrome view left behind by the Session 14 implementation,
            // then restore AppKit's normal fully opaque window appearance.
            window.contentView?.subviews
                .filter { $0.identifier == chromeIdentifier }
                .forEach { $0.removeFromSuperview() }
            window.isOpaque = true
            window.backgroundColor = nil
            window.titlebarAppearsTransparent = false
            return
        }

        // Fade at the window level. Never add a view to SwiftUI's managed
        // contentView hierarchy, particularly during updateNSView.
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(alpha)
        window.titlebarAppearsTransparent = true
    }
}

/// Which top-level section the detail pane shows (Session 7 Part A, #6): the
/// papers library (notebooks/tags/search/grid) or the new all-notes section.
private enum MainMode: Hashable {
    case papers
    case folders
    case notes
}

/// Hosts the `LibraryViewModel` and lays out the notebook sidebar, tag filters,
/// paper grid and search results as a `NavigationSplitView`.
private struct LibraryContentView: View {
    private static let expandedSummaryIDsDefaultsKey = "expandedNotebookSummaryIDs"

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var appearance: AppearanceManager
    @StateObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var mode: MainMode = .papers
    /// Whether the notebook-scope Claude panel (Session 7 Part B) is shown
    /// alongside the detail pane. Only meaningful — and only enabled from the
    /// toolbar — while a notebook is selected in the sidebar.
    @State private var isNotebookClaudePanelVisible: Bool = false
    @State private var isNotebookHighlightsPresented = false

    /// Click-vs-open selection state for the paper grid (Session 11). Kept
    /// here (rather than per-card) so shift-click ranges and ⌘O/⌘⌫ can see
    /// the whole selection.
    @StateObject private var selection = PaperSelectionController()
    /// Ids pending a delete confirmation; may be a single card (right-clicked
    /// or ⌘⌫'d while unselected) or the full multi-selection.
    @State private var idsPendingDeletion: Set<String>?
    @State private var isSearchOverlayVisible = false
    @State private var expandedNotebookSummaryIDs: Set<String>

    init(database: DatabaseManager) {
        _library = StateObject(wrappedValue: LibraryViewModel(database: database))
        let storedIDs = UserDefaults.standard.stringArray(
            forKey: Self.expandedSummaryIDsDefaultsKey
        ) ?? []
        _expandedNotebookSummaryIDs = State(initialValue: Set(storedIDs))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                detail

                // Session 7 Part B: notebook-scope Claude Q&A, opened from the
                // Home window for whichever notebook is currently selected.
                // Keyed by notebook id so switching the sidebar selection to a
                // different notebook while the panel is open rebuilds it and
                // loads that notebook's own persisted conversation.
                if isNotebookClaudePanelVisible, let notebook = selectedNotebook {
                    Divider()
                    ClaudePanelView(notebook: notebook, database: library.database)
                        .frame(width: appearance.aiPanelWidth)
                        .id(notebook.id)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isNotebookClaudePanelVisible)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNotebookHighlightsPresented = true
                } label: {
                    Label("Notebook Highlights", systemImage: "list.bullet.rectangle")
                }
                .help("Notebook Highlights")
                .disabled(selectedNotebook == nil)
                .sheet(isPresented: $isNotebookHighlightsPresented) {
                    if let notebook = selectedNotebook {
                        HighlightTaxonomyView(notebook: notebook, database: library.database) { paperId, page in
                            PendingReaderJump.set(paperId: paperId, pageIndex: page)
                            openWindow(value: paperId)
                        }
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNotebookClaudePanelVisible.toggle()
                } label: {
                    Label("Ask AI", systemImage: "sparkles")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Ask AI about the selected notebook")
                .disabled(selectedNotebook == nil)
            }
        }
        .alert(
            "Import",
            isPresented: Binding(
                get: { appState.importMessage != nil },
                set: { isPresented in
                    if !isPresented { appState.importMessage = nil }
                }
            )
        ) {
            Button("OK") { appState.importMessage = nil }
        } message: {
            Text(appState.importMessage ?? "")
        }
        .onAppear { library.refresh() }
        .onChange(of: library.selection) { _, _ in
            // Selecting any notebook (or the built-in All Papers/Unfiled rows)
            // inside NotebookTreeView always means "show the papers detail".
            mode = .papers
        }
        .overlay {
            if isSearchOverlayVisible {
                GlobalSearchOverlay(
                    library: library,
                    onSelect: openGlobalSearchResult,
                    onDismiss: { isSearchOverlayVisible = false }
                )
                .zIndex(100)
            }
        }
        .background {
            // App-local Shift+` shortcut: active only while Paper Reader's
            // main window is key; this is intentionally not a global hotkey.
            Button("Global Search") { isSearchOverlayVisible = true }
                .keyboardShortcut("`", modifiers: .shift)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            mainModeSwitcher

            Divider()

            NotebookTreeView(viewModel: library)

            Divider()

            ReadingStatusFilterView(library: library)

            Divider()

            TagFilterView(library: library)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    /// Top-level sidebar rows switching the whole detail pane between the
    /// papers library and the all-notes section (spec Session 7 Part A, #6).
    @ViewBuilder
    private var mainModeSwitcher: some View {
        VStack(alignment: .leading, spacing: 2) {
            mainModeRow(title: "All Papers", icon: "doc.on.doc", mode: .papers)
                .dropDestination(for: String.self) { items, _ in
                    var handledDrop = false
                    for item in items where item.hasPrefix("paper:") {
                        library.movePaper(
                            paperId: String(item.dropFirst("paper:".count)),
                            toNotebook: nil
                        )
                        handledDrop = true
                    }
                    return handledDrop
                }
            unfiledModeRow
            mainModeRow(title: "All Folders", icon: "folder", mode: .folders)
            mainModeRow(title: "Notes", icon: "note.text", mode: .notes)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func mainModeRow(title: String, icon: String, mode target: MainMode) -> some View {
        let isSelected = mode == target && (target != .papers || library.selection == .all)
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            mode = target
            if target == .papers {
                library.selection = .all
            }
        }
    }

    private var unfiledModeRow: some View {
        let isSelected = mode == .papers && library.selection == .unfiled

        return HStack(spacing: 6) {
            Image(systemName: "tray")
                .foregroundStyle(.secondary)
            Text("Unfiled")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            mode = .papers
            library.selection = .unfiled
        }
        .dropDestination(for: String.self) { items, _ in
            for item in items where item.hasPrefix("paper:") {
                library.movePaper(
                    paperId: String(item.dropFirst("paper:".count)),
                    toNotebook: nil
                )
            }
            return true
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch mode {
            case .notes:
                NotesLibraryView(database: library.database)
            case .folders:
                if let papersDir = appState.database?.papersDirectory {
                    AllFoldersView(
                        library: library,
                        papersDirectory: papersDir
                    ) { notebook in
                        library.selection = .notebook(notebook.id)
                        mode = .papers
                    }
                }
            case .papers:
                papersDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var papersDetail: some View {
        VStack(spacing: 0) {
            if !library.isSearching, let notebook = selectedNotebook {
                notebookSummaryHeader(notebook)
            }

            Group {
                if library.isSearching {
                    SearchResultsView(library: library, onOpen: openResult)
                } else {
                    paperLibraryPages
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(titleForSelection)
        .searchable(text: $library.searchText)
        .onChange(of: library.searchText) { _, _ in
            library.runSearch()
        }
        .background {
            // Hidden buttons (Session 11, Tasks 2 & 3): zero-visible-size so
            // they don't affect layout, but their keyboard shortcuts are live
            // whenever this window is key.
            Button("Open Selected") { openSelected() }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("Delete Selected", role: .destructive) {
                guard !selection.selectedIDs.isEmpty else { return }
                idsPendingDeletion = selection.selectedIDs
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .alert(
            deletionAlertTitle,
            isPresented: Binding(
                get: { idsPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { idsPendingDeletion = nil }
                }
            )
        ) {
            Button("Cancel", role: .cancel) { idsPendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let ids = idsPendingDeletion {
                    library.deletePapers(ids: ids)
                    selection.remove(ids)
                }
                idsPendingDeletion = nil
            }
        } message: {
            Text(deletionAlertMessage)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !library.isSearching {
                    Picker("Group By", selection: $library.grouping) {
                        ForEach(PaperGrouping.allCases, id: \.self) { grouping in
                            Text(grouping.label).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImportPanel()
                } label: {
                    Label("Import PDF", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    @ViewBuilder
    private var paperLibraryPages: some View {
        if let papersDir = appState.database?.papersDirectory {
            let hasSubfolders = library.selectedNotebookId
                .map { !library.childNotebooks(of: $0).isEmpty } ?? false
            if library.papers.isEmpty && !hasSubfolders {
                emptyStateView
            } else {
                PaperPagedLibraryView(
                    library: library,
                    selection: selection,
                    papersDirectory: papersDir,
                    onOpen: { id in openWindow(value: id) },
                    onRequestDelete: { ids in idsPendingDeletion = ids }
                )
            }
        }
    }

    /// The flat display order of every paper currently shown, used as the
    /// range for shift-click and as the ordering for ⌘O (Session 11). For
    /// `.flat` grouping this is just `library.papers`; for grouped modes it's
    /// each group's papers concatenated in display order.
    private var visibleOrderedIDs: [String] {
        if library.grouping == .flat {
            return library.papers.map(\.id)
        }
        return library.groupedPapers().flatMap { $0.papers.map(\.id) }
    }

    /// ⌘O (Session 11, Task 2): opens the current selection. A single
    /// selected paper opens its normal reader window; exactly two open as a
    /// side-by-side `ComparePairID` (Session 9); more than two open the first
    /// two as a compare pair and every remaining paper as its own reader
    /// window (judgment call — there's no "compare 3+" UI to route into).
    private func openSelected() {
        let orderedSelectedIDs = visibleOrderedIDs.filter { selection.selectedIDs.contains($0) }
        guard !orderedSelectedIDs.isEmpty else { return }

        if orderedSelectedIDs.count == 1 {
            openWindow(value: orderedSelectedIDs[0])
        } else {
            openWindow(value: ComparePairID(leftPaperId: orderedSelectedIDs[0], rightPaperId: orderedSelectedIDs[1]))
            for id in orderedSelectedIDs.dropFirst(2) {
                openWindow(value: id)
            }
        }
    }

    private func openGlobalSearchResult(_ result: GlobalSearchResult) {
        isSearchOverlayVisible = false
        switch result {
        case .paper(let id, _):
            openWindow(value: id)
        case .notebook(let id, _):
            library.selection = .notebook(id)
            mode = .papers
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private var deletionAlertTitle: String {
        guard let ids = idsPendingDeletion else { return "" }
        return ids.count > 1 ? "Delete \(ids.count) papers?" : "Delete this paper?"
    }

    private var deletionAlertMessage: String {
        guard let ids = idsPendingDeletion else { return "" }
        if ids.count > 1 {
            return "Delete \(ids.count) papers? This removes each PDF and all its highlights, comments, and notes. This can't be undone."
        }
        return "This removes the PDF and all its highlights, comments, and notes. This can't be undone."
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Text("No papers yet")
                .font(.title2.bold())
            Text("Click Import PDF to add one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }

    /// The `Notebook` behind `library.selection`, or nil if the selection is
    /// `.all`/`.unfiled` (used to gate and target the notebook-scope Claude panel).
    private var selectedNotebook: Notebook? {
        guard case .notebook(let id) = library.selection else { return nil }
        return library.notebooks.first(where: { $0.id == id })
    }

    /// AI-generated summary header shown above the paper grid whenever a
    /// notebook is selected (Session 10, Feature 3). Reads the cached
    /// `Notebook.aiSummary` — never triggers generation itself; that happens
    /// automatically (via `NotebookSummaryService`) whenever this notebook's
    /// paper set changes. Refreshes live because
    /// `LibraryViewModel` reloads `notebooks` on `.notebookSummaryDidUpdate`.
    @ViewBuilder
    private func notebookSummaryHeader(_ notebook: Notebook) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Notebook Summary", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                let summary = notebook.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if summary.isEmpty {
                    Text("No summary yet — it's generated automatically when papers are added to this notebook.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if expandedNotebookSummaryIDs.contains(notebook.id) {
                    ScrollView {
                        FormattedMarkdownText(
                            content: summary,
                            baseFont: .callout,
                            baseFontSize: NSFont.preferredFont(forTextStyle: .callout).pointSize
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)

                    Button("Show less") {
                        setNotebookSummaryExpanded(false, notebookID: notebook.id)
                    }
                    .buttonStyle(.link)
                } else {
                    Text(summaryPreview(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    Button("Show more") {
                        setNotebookSummaryExpanded(true, notebookID: notebook.id)
                    }
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding([.horizontal, .top], 20)
    }

    private func summaryPreview(_ summary: String) -> String {
        let compact = summary
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard compact.count > 200 else { return compact }
        return String(compact.prefix(200)) + "…"
    }

    private func setNotebookSummaryExpanded(_ isExpanded: Bool, notebookID: String) {
        if isExpanded {
            expandedNotebookSummaryIDs.insert(notebookID)
        } else {
            expandedNotebookSummaryIDs.remove(notebookID)
        }
        UserDefaults.standard.set(
            expandedNotebookSummaryIDs.sorted(),
            forKey: Self.expandedSummaryIDsDefaultsKey
        )
    }

    private var titleForSelection: String {
        switch library.selection {
        case .all:
            return "All Papers"
        case .unfiled:
            return "Unfiled"
        case .notebook(let id):
            return library.notebooks.first(where: { $0.id == id })?.name ?? "Notebook"
        }
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            appState.importPapers(from: panel.urls)
            library.refresh()
        }
    }

    /// Jumps to the entity behind a search result: opens the reader for a paper
    /// hit, the notes window for a note hit, or the reader plus a highlight jump
    /// for a comment hit.
    private func openResult(_ result: SearchResult) {
        switch result.entityType {
        case .paper:
            library.searchText = ""
            library.selection = .all
            openWindow(value: result.id)

        case .note:
            guard let paperId = result.paperId else { return }
            openWindow(value: NotesWindowID(paperId: paperId))

        case .comment:
            guard let paperId = result.paperId else { return }
            openWindow(value: paperId)
            if let page = try? library.database.dbQueue.read({ db -> Int? in
                guard let hid = try String.fetchOne(db, sql: "SELECT highlight_id FROM comment WHERE id = ?", arguments: [result.id]) else { return nil }
                return try Int.fetchOne(db, sql: "SELECT page FROM highlight WHERE id = ?", arguments: [hid])
            }) ?? nil {
                NotificationCenter.default.post(
                    name: .readerJumpToHighlight, object: nil,
                    userInfo: ["paperId": paperId, "pageIndex": page]
                )
            }
        }
    }
}

struct ReadingStatusFilterView: View {
    @ObservedObject var library: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reading Status")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Picker("Reading Status", selection: $library.statusFilter) {
                Text("All").tag(String?.none)
                ForEach(ReadingStatus.allCases) { status in
                    Text(status.label).tag(Optional(status.rawValue))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(8)
    }
}

/// Sidebar section listing every tag as a toggleable filter chip (spec Session
/// 5 Part A.2). Hidden entirely when the library has no tags yet.
struct TagFilterView: View {
    @ObservedObject var library: LibraryViewModel
    @State private var tagPendingDeletion: Tag?

    var body: some View {
        if !library.allTags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(library.allTags) { tag in
                            tagChip(tag)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 160)
            }
            .padding(.vertical, 8)
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(
                    get: { tagPendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented { tagPendingDeletion = nil }
                    }
                ),
                presenting: tagPendingDeletion
            ) { tag in
                Button("Delete", role: .destructive) {
                    library.deleteTag(id: tag.id)
                    tagPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    tagPendingDeletion = nil
                }
            } message: { tag in
                Text("This will remove \u{201C}\(tag.name)\u{201D} from all papers. This can't be undone.")
            }
        }
    }

    private var deletionTitle: String {
        guard let tag = tagPendingDeletion else { return "" }
        return "Delete \u{201C}\(tag.name)\u{201D}?"
    }

    @ViewBuilder
    private func tagChip(_ tag: Tag) -> some View {
        let isActive = library.isTagFilterActive(tag.id)
        Button {
            library.toggleTagFilter(tag.id)
        } label: {
            Text(tag.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isActive ? Color.accentColor : Color.secondary.opacity(0.15))
                )
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Tag", role: .destructive) {
                tagPendingDeletion = tag
            }
        }
    }
}

/// Simple left-to-right wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Flat list of full-text search hits (spec Session 5 Part A.3). Each row shows
/// an icon by entity type, a type label, and the matched snippet.
struct SearchResultsView: View {
    @ObservedObject var library: LibraryViewModel
    let onOpen: (SearchResult) -> Void

    var body: some View {
        List(library.searchResults) { result in
            Button {
                onOpen(result)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: result.entityType))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(for: result.entityType))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(result.snippet)
                            .font(.body)
                            .lineLimit(3)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if library.searchResults.isEmpty {
                Text("No results")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for type: SearchEntityType) -> String {
        switch type {
        case .paper: return "doc"
        case .note: return "note.text"
        case .comment: return "text.bubble"
        }
    }

    private func label(for type: SearchEntityType) -> String {
        switch type {
        case .paper: return "Paper"
        case .note: return "Note"
        case .comment: return "Comment"
        }
    }
}
