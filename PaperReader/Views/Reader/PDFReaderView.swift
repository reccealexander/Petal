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

    init(paper: Paper, database: DatabaseManager) {
        self.paper = paper
        self.database = database
    }

    var body: some View {
        PDFKitWrapper(url: PDFImportService.fileURL(for: paper, in: database.papersDirectory))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(paper.title ?? "Untitled")
            .onAppear { updateLastOpened() }
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
