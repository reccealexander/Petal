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

    var body: some View {
        Group {
            if let db = appState.database {
                LibraryContentView(database: db)
            } else {
                databaseErrorView
            }
        }
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

/// Hosts the `LibraryViewModel` and lays out the notebook sidebar, tag filters,
/// paper grid and search results as a `NavigationSplitView`.
private struct LibraryContentView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var library: LibraryViewModel
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 20)]

    init(database: DatabaseManager) {
        _library = StateObject(wrappedValue: LibraryViewModel(database: database))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
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
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            NotebookTreeView(viewModel: library)

            Divider()

            TagFilterView(library: library)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if library.isSearching {
                SearchResultsView(library: library, onOpen: openResult)
            } else {
                paperGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(titleForSelection)
        .searchable(text: $library.searchText)
        .onChange(of: library.searchText) { _, _ in
            library.runSearch()
        }
        .toolbar {
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
    private var paperGrid: some View {
        if let papersDir = appState.database?.papersDirectory {
            if library.papers.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(library.papers) { paper in
                            Button {
                                openWindow(value: paper.id)
                            } label: {
                                PaperCardView(paper: paper, papersDirectory: papersDir, library: library)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
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
