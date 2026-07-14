import SwiftUI
import PetalCore
import GRDB

/// Identifies an open side-by-side compare window by the paper ids shown in
/// its left and right panes. `Hashable, Codable` so it can key a `WindowGroup`
/// the same way the standalone reader window is keyed by a raw paper id
/// (see `PetalApp.body`).
struct ComparePairID: Hashable, Codable {
    let leftPaperId: String
    let rightPaperId: String
}

/// Resolves both papers for a `ComparePairID` from the shared database and
/// hosts `CompareReaderView`. Mirrors `ReaderWindow`'s resolve-by-id pattern
/// in `PetalApp.swift`.
struct CompareReaderRoot: View {
    @EnvironmentObject private var appState: AppState
    let pair: ComparePairID?

    var body: some View {
        if let pair, let db = appState.database,
           let left = try? db.dbQueue.read({ try Paper.fetchOne($0, key: pair.leftPaperId) }),
           let right = try? db.dbQueue.read({ try Paper.fetchOne($0, key: pair.rightPaperId) }) {
            CompareReaderView(left: left, right: right, database: db)
        } else {
            Text("Paper not found").foregroundStyle(.secondary)
        }
    }
}

/// Session 9 Part A: two `PDFReaderView`s side by side in one window, each
/// independently scrollable/zoomable — each pane instantiates its own
/// `PDFReaderView`, which owns its own `PDFReaderModel`/`PDFView`, so scroll
/// position and zoom are independent by construction. No second PDF-rendering
/// path was built; both panes reuse the existing reader exactly as-is.
///
/// `HSplitView` provides the required user-draggable divider between the two
/// panes for free.
///
/// Toolbar approach (flagged per the session brief): `PDFReaderView` declares
/// its own `.toolbar`, and two instances directly inside one window would
/// both contribute items to the single shared window toolbar (two "Notes"
/// buttons, two highlight-color groups, etc., with no indication of which
/// pane they act on). Wrapping each pane in its own `NavigationStack` gives
/// each `PDFReaderView` its own per-pane toolbar bar instead of merging into
/// the window chrome — this worked on the first attempt, so the "shared
/// title bar" fallback mentioned in the brief wasn't needed.
struct CompareReaderView: View {
    let left: Paper
    let right: Paper
    let database: DatabaseManager

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            NavigationStack {
                PDFReaderView(paper: left, database: database, isStandaloneWindow: false)
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            NavigationStack {
                PDFReaderView(paper: right, database: database, isStandaloneWindow: false)
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    splitOut()
                } label: {
                    Label("Split into windows", systemImage: "rectangle.split.1x2")
                }
                .help("Split back into two separate windows")
            }
        }
    }

    /// Un-snap (required): reopens each paper as its own standalone reader
    /// window, then closes this compare window.
    private func splitOut() {
        openWindow(value: left.id)
        openWindow(value: right.id)
        dismiss()
    }
}
