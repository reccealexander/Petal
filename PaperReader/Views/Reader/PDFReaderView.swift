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
struct PDFReaderView: View {
    let paper: Paper
    let database: DatabaseManager

    @StateObject private var model = PDFReaderModel()
    @StateObject private var thumbnailProvider: PageThumbnailProvider
    @Environment(\.openWindow) private var openWindow

    init(paper: Paper, database: DatabaseManager) {
        self.paper = paper
        self.database = database
        let document = PDFDocument(url: PDFImportService.fileURL(for: paper, in: database.papersDirectory))
        _thumbnailProvider = StateObject(wrappedValue: PageThumbnailProvider(
            paperId: paper.id,
            document: document,
            papersDirectory: database.papersDirectory
        ))
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
                ClaudePanelView(paper: paper, database: database)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
            .animation(.easeInOut(duration: 0.2), value: model.isThumbnailSidebarVisible)
            .animation(.easeInOut(duration: 0.2), value: model.isClaudePanelVisible)
            .navigationTitle(paper.title ?? "Untitled")
            .onAppear { updateLastOpened() }
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

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isClaudePanelVisible.toggle()
                    } label: {
                        Label("Ask Claude", systemImage: "sparkles")
                    }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .help("Ask Claude about this paper")
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
            }
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
