import SwiftUI
import PaperReaderCore
import GRDB

enum JoinablePaneRef: Hashable, Codable {
    case reader(paperId: String)
    case notes(paperId: String)
    case main
}

struct JoinedWindowID: Hashable, Codable {
    let left: JoinablePaneRef
    let right: JoinablePaneRef
}

struct JoinedWindowRoot: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var snapController: WindowSnapController
    let pair: JoinedWindowID?

    var body: some View {
        if let pair, let database = appState.database {
            JoinedWindowView(pair: pair, database: database)
                // Once the standalone main window has joined and closed, the
                // joined window becomes the owner of the openWindow bridge.
                .background(WindowJoinBridge(controller: snapController))
        } else {
            Text("Content unavailable").foregroundStyle(.secondary)
        }
    }
}

private struct JoinedWindowView: View {
    let pair: JoinedWindowID
    let database: DatabaseManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            pane(pair.left)
            pane(pair.right)
        }
        .frame(minWidth: 900, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: splitOut) {
                    Label("Split out", systemImage: "rectangle.split.1x2")
                }
                .help("Split back into separate windows")
            }
        }
    }

    @ViewBuilder
    private func pane(_ ref: JoinablePaneRef) -> some View {
        NavigationStack {
            switch ref {
            case .reader(let paperId):
                if let paper = paper(paperId) {
                    PDFReaderView(paper: paper, database: database, isStandaloneWindow: false)
                } else { unavailable }
            case .notes(let paperId):
                if let paper = paper(paperId) {
                    NotesView(paperId: paper.id, paperTitle: paper.title ?? "Untitled", database: database)
                } else { unavailable }
            case .main:
                HomeView()
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        Text("Content unavailable").foregroundStyle(.secondary)
    }

    private func paper(_ id: String) -> Paper? {
        try? database.dbQueue.read { try Paper.fetchOne($0, key: id) }
    }

    private func splitOut() {
        reopen(pair.left)
        reopen(pair.right)
        dismiss()
    }

    private func reopen(_ ref: JoinablePaneRef) {
        switch ref {
        case .reader(let id): openWindow(value: id)
        case .notes(let id): openWindow(value: NotesWindowID(paperId: id))
        case .main: openWindow(id: "main-library")
        }
    }
}
