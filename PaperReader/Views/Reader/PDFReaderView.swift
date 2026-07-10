import SwiftUI
import GRDB
import PaperReaderCore

/// Full-window PDF reading surface for a single `Paper` (spec §3 Phase 1).
///
/// Resolves the paper's on-disk PDF via `PDFImportService.fileURL(for:in:)` and
/// hands it to `PDFKitWrapper` for rendering. Records that the paper was opened
/// by stamping `last_opened_at` when the view appears.
struct PDFReaderView: View {
    let paper: Paper
    let database: DatabaseManager

    @StateObject private var model = PDFReaderModel()
    @Environment(\.openWindow) private var openWindow

    init(paper: Paper, database: DatabaseManager) {
        self.paper = paper
        self.database = database
    }

    var body: some View {
        PDFKitWrapper(
            url: PDFImportService.fileURL(for: paper, in: database.papersDirectory),
            paper: paper,
            database: database,
            model: model
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(paper.title ?? "Untitled")
            .onAppear { updateLastOpened() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openWindow(value: NotesWindowID(paperId: paper.id))
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .help("Open notes for this paper")
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
