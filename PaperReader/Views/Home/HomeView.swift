import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperReaderCore

/// The app's home screen (spec §3 Phase 1): a grid of imported papers plus an
/// "Import PDF" action. Tapping a card opens the paper in its own reader window.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if appState.database == nil {
                    databaseErrorView
                } else if appState.papers.isEmpty {
                    emptyStateView
                } else {
                    papersGrid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("PaperReader")
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

    @ViewBuilder
    private var papersGrid: some View {
        if let papersDir = appState.database?.papersDirectory {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(appState.papers) { paper in
                        Button {
                            openWindow(value: paper.id)
                        } label: {
                            PaperCardView(paper: paper, papersDirectory: papersDir)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    private func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            appState.importPapers(from: panel.urls)
        }
    }
}
