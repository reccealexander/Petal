import SwiftUI
import AppKit

/// Registry and drag-adjacency detector shared by every joinable window.
/// The AppKit heuristic is intentionally the same best-effort heuristic used
/// by Session 9's reader-only compare coordinator.
@MainActor
final class WindowSnapController: ObservableObject {
    private var windows: [JoinablePaneRef: NSWindow] = [:]
    private var moveObservers: [JoinablePaneRef: NSObjectProtocol] = [:]

    @Published var pendingJoin: JoinedWindowID?
    private var isJoining = false

    func register(ref: JoinablePaneRef, window: NSWindow) {
        // SwiftUI may resolve the accessor more than once. Do not tear down a
        // valid observer when it resolves to the same hosting window.
        if windows[ref] === window { return }
        unregister(ref: ref)
        windows[ref] = window
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMove(of: ref)
            }
        }
        moveObservers[ref] = token
    }

    func unregister(ref: JoinablePaneRef) {
        if let token = moveObservers.removeValue(forKey: ref) {
            NotificationCenter.default.removeObserver(token)
        }
        windows.removeValue(forKey: ref)
    }

    func closeStandaloneWindowIfOpen(paperId: String) {
        windows[.reader(paperId: paperId)]?.close()
    }

    func closeJoinedSourceWindows(_ pair: JoinedWindowID) {
        windows[pair.left]?.close()
        windows[pair.right]?.close()
        isJoining = false
    }

    private func handleMove(of ref: JoinablePaneRef) {
        guard !isJoining, pendingJoin == nil, let movedWindow = windows[ref] else { return }
        let movedFrame = movedWindow.frame

        for (otherRef, otherWindow) in windows where otherRef != ref {
            let otherFrame = otherWindow.frame
            let leftRef: JoinablePaneRef
            let leftFrame: CGRect
            let rightRef: JoinablePaneRef
            let rightFrame: CGRect
            if movedFrame.minX <= otherFrame.minX {
                (leftRef, leftFrame, rightRef, rightFrame) = (ref, movedFrame, otherRef, otherFrame)
            } else {
                (leftRef, leftFrame, rightRef, rightFrame) = (otherRef, otherFrame, ref, movedFrame)
            }

            guard abs(rightFrame.minX - leftFrame.maxX) < 20 else { continue }
            let verticalOverlap = max(0, min(leftFrame.maxY, rightFrame.maxY) - max(leftFrame.minY, rightFrame.minY))
            let shorterHeight = min(leftFrame.height, rightFrame.height)
            guard shorterHeight > 0, verticalOverlap / shorterHeight > 0.5 else { continue }
            guard abs(leftFrame.maxY - rightFrame.maxY) < 40 else { continue }

            isJoining = true
            pendingJoin = JoinedWindowID(left: leftRef, right: rightRef)
            return
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct WindowJoinBridge: View {
    @ObservedObject var controller: WindowSnapController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onChange(of: controller.pendingJoin) { _, pair in
                guard let pair else { return }
                openWindow(value: pair)
                controller.closeJoinedSourceWindows(pair)
                controller.pendingJoin = nil
            }
    }
}
