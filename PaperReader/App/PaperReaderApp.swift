import SwiftUI
import PaperReaderCore
import GRDB

/// App entry point (spec §2). The main window shows `HomeView`; each opened
/// paper gets its own reader window keyed by `Paper.id`.
@main
struct PaperReaderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("PaperReader") {
            HomeView()
                .environmentObject(appState)
                .frame(minWidth: 480, minHeight: 320)
        }

        WindowGroup(for: String.self) { $paperId in
            ReaderWindow(paperId: paperId)
                .environmentObject(appState)
        }
    }
}

/// Resolves a `Paper` by id from the shared database and hosts `PDFReaderView`.
private struct ReaderWindow: View {
    @EnvironmentObject private var appState: AppState
    let paperId: String?

    var body: some View {
        if let paperId, let db = appState.database,
           let paper = try? db.dbQueue.read({ try Paper.fetchOne($0, key: paperId) }) {
            PDFReaderView(paper: paper, database: db)
        } else {
            Text("Paper not found").foregroundStyle(.secondary)
        }
    }
}

/// Placeholder launch screen, kept for reference (unused by any scene).
private struct LaunchStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("PaperReader")
                .font(.largeTitle.bold())

            statusView
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.databaseStatus {
        case .initializing:
            ProgressView("Initializing database…")

        case let .ready(migrations, path):
            VStack(spacing: 6) {
                Label("Database initialized", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Migrations applied: \(migrations.joined(separator: ", "))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

        case let .failed(message):
            VStack(spacing: 6) {
                Label("Database failed to initialize", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
