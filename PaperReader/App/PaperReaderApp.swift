import SwiftUI
import AppKit
import PaperReaderCore
import GRDB

/// Promotes the process to a regular foreground app so windows and popovers can
/// become key (a bare SwiftPM executable otherwise launches without a proper
/// activation policy, which blocks keyboard focus in secondary windows/popovers
/// and hides the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Observer tokens for the notifications used to keep the main SwiftUI
    /// window hidden while the splash is showing. Removed once the splash
    /// dismisses so later user-opened windows (reader/notes) are never
    /// affected.
    private var hideObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Icon-on-white splash that stays up indefinitely (no timer) until
        // the user clicks "Research Now", at which point the main window is
        // revealed.
        SplashWindowController.show(onResearchNow: { [weak self] in
            self?.revealMainWindow()
        })

        // SwiftUI creates/shows its WindowGroup window asynchronously around
        // launch time — it may not exist yet, or may appear a moment after
        // this method returns. Hide whatever non-splash windows exist right
        // now, again on the next runloop turn, and keep hiding any non-splash
        // window that becomes key or updates for as long as the splash is
        // active, so the main window never has a chance to flash on screen
        // before the splash finishes.
        hideNonSplashWindows()
        DispatchQueue.main.async { [weak self] in
            self?.hideNonSplashWindows()
        }

        // Notification objects (and the NSWindow they reference) aren't
        // Sendable, so rather than pluck the window out of the notification
        // itself (which would require sending a non-Sendable value across
        // the actor boundary into the assumeIsolated closure below), just
        // re-sweep all current windows whenever either notification fires.
        let center = NotificationCenter.default
        let hideIfNeeded: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                guard SplashWindowController.isActive else { return }
                for window in NSApp.windows where !SplashWindowController.isSplashWindow(window) {
                    window.orderOut(nil)
                }
            }
        }
        hideObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: hideIfNeeded),
            center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main, using: hideIfNeeded),
        ]
    }

    @MainActor
    private func hideNonSplashWindows() {
        for window in NSApp.windows where !SplashWindowController.isSplashWindow(window) {
            window.orderOut(nil)
        }
    }

    /// Dismisses the splash, stops hiding non-splash windows, and brings the
    /// main SwiftUI window to the front as key — timed so the main window
    /// appears just as the splash fades out.
    @MainActor
    private func revealMainWindow() {
        SplashWindowController.dismiss()

        let center = NotificationCenter.default
        for observer in hideObservers {
            center.removeObserver(observer)
        }
        hideObservers.removeAll()

        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !SplashWindowController.isSplashWindow(window) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// App entry point (spec §2). The main window shows `HomeView`; each opened
/// paper gets its own reader window keyed by `Paper.id`.
@main
struct PaperReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var appearance = AppearanceManager()
    // Session 9 Part A: drag-to-snap registry for standalone reader windows
    // (best effort, not GUI-verified — see CompareCoordinator.swift). Created
    // once here so every window scene shares the same instance.
    @StateObject private var snapController = WindowSnapController()
    @StateObject private var focusController = FocusModeController()

    var body: some Scene {
        Window("PaperReader", id: "main-library") {
            HomeView()
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
                .frame(minWidth: 480, minHeight: 320)
                // Invisible listener that turns a detected drag-to-snap pair
                // into an actual openWindow call (AppKit-side detection code
                // has no SwiftUI environment to call openWindow from itself).
                .background {
                    WindowAccessor { window in
                        snapController.register(ref: .main, window: window)
                    }
                }
                .background(WindowJoinBridge(controller: snapController))
                .onDisappear { snapController.unregister(ref: .main) }
        }
        .commands {
            CommandMenu("View") {
                FocusModeCommands(controller: focusController)
            }
        }

        WindowGroup(for: String.self) { $paperId in
            ReaderWindow(paperId: paperId)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
        }
        .commands {
            CommandMenu("View") {
                FocusModeCommands(controller: focusController)
            }
        }

        // Session 9 Part A: side-by-side compare window for two papers,
        // reached via PDFReaderView's "Compare side-by-side" menu (explicit,
        // required path) or via drag-to-snap (best effort). Mirrors the
        // reader WindowGroup's resolve-by-id pattern via CompareReaderRoot.
        WindowGroup(for: ComparePairID.self) { $pair in
            CompareReaderRoot(pair: pair)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
        }

        WindowGroup(for: JoinedWindowID.self) { $pair in
            JoinedWindowRoot(pair: pair)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
        }

        WindowGroup(for: NotesWindowID.self) { $notesID in
            NotesWindowRoot(notesID: notesID)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
        }

        WindowGroup(for: ChatWindowID.self) { $chatID in
            ChatWindowRoot(chatID: chatID)
                .environmentObject(appState)
                .environmentObject(appearance)
                .environmentObject(snapController)
                .environmentObject(focusController)
        }

        // Standard Settings scene — macOS automatically binds this to the
        // "PaperReader > Preferences…" menu item and the ⌘, shortcut.
        Settings {
            SettingsView()
                .environmentObject(appearance)
        }
    }
}

private struct FocusModeCommands: View {
    @ObservedObject var controller: FocusModeController

    var body: some View {
        Button("Exit Focus Mode") {
            controller.exit()
        }
        .keyboardShortcut(.escape, modifiers: [])
        .disabled(!controller.isActive)
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

/// Resolves a `Paper` for a notes-window id and hosts `NotesView`.
private struct NotesWindowRoot: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var snapController: WindowSnapController
    @Environment(\.dismiss) private var dismiss
    let notesID: NotesWindowID?

    var body: some View {
        if let notesID, let db = appState.database,
           let paper = try? db.dbQueue.read({ try Paper.fetchOne($0, key: notesID.paperId) }) {
            NotesView(paperId: paper.id, paperTitle: paper.title ?? "Untitled", database: db)
                .background {
                    WindowAccessor { window in
                        snapController.register(ref: .notes(paperId: paper.id), window: window)
                    }
                }
                .onDisappear {
                    snapController.unregister(ref: .notes(paperId: paper.id))
                }
                .onReceive(NotificationCenter.default.publisher(for: .notesPaneShouldClose)) { notification in
                    guard NotesPaneCloseRequest.paperId(from: notification) == paper.id else { return }
                    dismiss()
                }
        } else {
            Text("Note unavailable").foregroundStyle(.secondary)
        }
    }
}

/// Resolves the requested reader chat scope while reusing its persisted session.
private struct ChatWindowRoot: View {
    @EnvironmentObject private var appState: AppState
    let chatID: ChatWindowID?

    var body: some View {
        Group {
            if let chatID, let db = appState.database,
               let paper = try? db.dbQueue.read({ try Paper.fetchOne($0, key: chatID.paperId) }) {
                ClaudePanelView(
                    paper: paper,
                    database: db,
                    initialNotebookScope: chatID.isNotebookScope
                )
            } else {
                Text("Chat unavailable").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 360, minHeight: 420)
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
