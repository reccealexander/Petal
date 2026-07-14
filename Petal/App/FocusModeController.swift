import AppKit
import Combine

/// Owns the desktop-wide state changes made while a reader is in Focus mode.
@MainActor
final class FocusModeController: ObservableObject {
    @Published private(set) var isActive = false

    private var hiddenApps: [NSRunningApplication] = []
    private var hiddenWindows: [NSWindow] = []
    private weak var focusedWindow: NSWindow?
    private var terminationObserver: NSObjectProtocol?

    init() {
        // Safety net: if the user quits Petal (⌘Q) while Focus mode is active,
        // SwiftUI's onDisappear/onExitCommand may not run — so `exit()` would
        // never fire and the user's other apps would stay hidden system-wide.
        // `willTerminateNotification` is delivered during graceful termination,
        // so restore everything there. (A crash can't be covered.)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.exit() }
        }
    }

    func enter(focusedWindow: NSWindow?) {
        guard !isActive else { return }

        self.focusedWindow = focusedWindow

        hiddenApps.removeAll()
        for app in NSWorkspace.shared.runningApplications
        where app != NSRunningApplication.current &&
              app.activationPolicy == .regular &&
              !app.isHidden {
            app.hide()
            hiddenApps.append(app)
        }

        hiddenWindows.removeAll()
        for window in NSApp.windows
        where window !== focusedWindow &&
              !SplashWindowController.isSplashWindow(window) &&
              window.isVisible {
            hiddenWindows.append(window)
            window.orderOut(nil)
        }

        isActive = true
        focusedWindow?.makeKeyAndOrderFront(nil)
    }

    func exit() {
        guard isActive else { return }

        for app in hiddenApps {
            app.unhide()
        }
        hiddenApps.removeAll()

        for window in hiddenWindows where !window.isVisible {
            window.orderBack(nil)
        }
        hiddenWindows.removeAll()

        isActive = false
        NSApp.activate(ignoringOtherApps: true)
        focusedWindow?.makeKeyAndOrderFront(nil)
        focusedWindow = nil
    }
}
