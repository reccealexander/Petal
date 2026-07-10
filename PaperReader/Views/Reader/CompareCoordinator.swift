import SwiftUI
import AppKit

/// Session 9 Part A (best effort, NOT GUI-VERIFIED): registry of currently
/// open standalone reader windows, used to detect drag-to-snap. When a
/// registered reader window is dragged so its edge lines up closely with
/// another registered reader window's opposite edge (and the two are
/// reasonably aligned vertically), the coordinator treats that as a request
/// to merge the pair into a side-by-side compare window.
///
/// This is deliberately conservative and additive: the REQUIRED, reliable
/// path is the explicit "Compare side-by-side" menu in `PDFReaderView`'s
/// toolbar (see `CompareReaderView.swift`), which does not depend on this
/// class at all. Drag-to-snap has not been exercised in an interactive GUI
/// session — only reasoned through and compiled — so treat the heuristic
/// below as best-effort rather than verified behavior.
///
/// Only standalone reader windows ever register here (`PDFReaderView` panes
/// embedded inside a `CompareReaderView` pass `isStandaloneWindow: false` and
/// never call `registerReaderWindow`). Home, notes, settings, and compare
/// windows are never registered, so they can never be snap-merged.
@MainActor
final class CompareCoordinator: ObservableObject {
    /// paperId -> its standalone reader NSWindow, while that window is open.
    private var readerWindows: [String: NSWindow] = [:]
    /// paperId -> the notification-observer token for that window's moves.
    private var moveObservers: [String: NSObjectProtocol] = [:]

    /// Set when a snap is detected; consumed by `CompareSnapBridge` (in
    /// `PaperReaderApp.swift`), which is the only place that can actually
    /// call `openWindow` — AppKit-side code here has no SwiftUI environment.
    @Published var pendingSnap: ComparePairID?

    /// Guards against re-triggering while a snap is already being handled
    /// (opening the compare window / closing the two source windows is not
    /// instantaneous, and window-move notifications can fire in bursts).
    private var isSnapping = false

    /// Registers `window` as the standalone reader window for `paperId` and
    /// starts watching it for moves. Call from `PDFReaderView.onAppear` (via
    /// `WindowAccessor`) — standalone windows only.
    func registerReaderWindow(paperId: String, window: NSWindow) {
        unregisterReaderWindow(paperId: paperId)
        readerWindows[paperId] = window
        // Mirrors `AppDelegate`'s notification-observer pattern in
        // PaperReaderApp.swift: the closure is `@Sendable` and does its real
        // work inside `MainActor.assumeIsolated`. Rather than pulling the
        // (non-Sendable) NSWindow out of the notification's `object` payload,
        // it captures only the Sendable `paperId` and looks the window back
        // up from the main-actor-isolated registry.
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMove(of: paperId)
            }
        }
        moveObservers[paperId] = token
    }

    /// Stops tracking `paperId`'s reader window. Call from
    /// `PDFReaderView.onDisappear` — standalone windows only.
    func unregisterReaderWindow(paperId: String) {
        if let token = moveObservers.removeValue(forKey: paperId) {
            NotificationCenter.default.removeObserver(token)
        }
        readerWindows.removeValue(forKey: paperId)
    }

    /// Best-effort: if `paperId` currently has its own standalone reader
    /// window open, close it. Used by the explicit "Compare side-by-side"
    /// trigger so picking an already-open paper doesn't leave a stray
    /// duplicate window behind.
    func closeStandaloneWindowIfOpen(paperId: String) {
        readerWindows[paperId]?.close()
    }

    /// Closes the two source reader windows that were just merged into a
    /// compare window. Called by `CompareSnapBridge` after it has opened the
    /// compare window for `pair`.
    func closeSnappedSourceWindows(pair: ComparePairID) {
        readerWindows[pair.leftPaperId]?.close()
        readerWindows[pair.rightPaperId]?.close()
        isSnapping = false
    }

    /// Checks the moved window (identified by `paperId`) against every other
    /// registered reader window for a snap: facing edges within ~20pt
    /// horizontally, with vertical overlap covering more than half of the
    /// shorter window's height and top edges within ~40pt of each other.
    private func handleMove(of paperId: String) {
        guard !isSnapping, pendingSnap == nil else { return }
        guard let movedWindow = readerWindows[paperId] else { return }
        let movedFrame = movedWindow.frame

        for (otherPaperId, otherWindow) in readerWindows where otherPaperId != paperId {
            let otherFrame = otherWindow.frame

            // Order left/right by x-position so we always compare the right
            // edge of the left one against the left edge of the right one.
            let (leftId, leftFrame, rightId, rightFrame): (String, CGRect, String, CGRect)
            if movedFrame.minX <= otherFrame.minX {
                (leftId, leftFrame, rightId, rightFrame) = (paperId, movedFrame, otherPaperId, otherFrame)
            } else {
                (leftId, leftFrame, rightId, rightFrame) = (otherPaperId, otherFrame, paperId, movedFrame)
            }

            let horizontalGap = abs(rightFrame.minX - leftFrame.maxX)
            guard horizontalGap < 20 else { continue }

            let overlapTop = min(leftFrame.maxY, rightFrame.maxY)
            let overlapBottom = max(leftFrame.minY, rightFrame.minY)
            let verticalOverlap = max(0, overlapTop - overlapBottom)
            let shorterHeight = min(leftFrame.height, rightFrame.height)
            guard shorterHeight > 0, verticalOverlap / shorterHeight > 0.5 else { continue }
            guard abs(leftFrame.maxY - rightFrame.maxY) < 40 else { continue }

            isSnapping = true
            pendingSnap = ComparePairID(leftPaperId: leftId, rightPaperId: rightId)
            return
        }
    }
}

/// Captures the hosting `NSWindow` on the next runloop turn (the view's
/// `window` property isn't populated yet at `makeNSView` time) and hands it
/// to `onResolve`. An invisible, zero-size helper placed in `PDFReaderView`'s
/// background so standalone reader windows can register with
/// `CompareCoordinator` for drag-to-snap detection.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Invisible listener, placed in the Home window's view hierarchy, that
/// bridges `CompareCoordinator.pendingSnap` into SwiftUI: AppKit-side code
/// (the coordinator's window-move observer) has no `openWindow` action, so it
/// just publishes the detected pair and this view does the actual
/// `openWindow` + cleanup once SwiftUI notices the change.
///
/// NOT GUI-VERIFIED — see `CompareCoordinator`.
struct CompareSnapBridge: View {
    @ObservedObject var coordinator: CompareCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onChange(of: coordinator.pendingSnap) { _, pair in
                guard let pair else { return }
                openWindow(value: pair)
                coordinator.closeSnappedSourceWindows(pair: pair)
                coordinator.pendingSnap = nil
            }
    }
}
