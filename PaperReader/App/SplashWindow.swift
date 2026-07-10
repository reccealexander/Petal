import AppKit

/// Minimal pre-main-window launch splash: a borderless, floating `NSWindow`
/// showing only the app icon itself, clipped to a rounded square, floating
/// with no surrounding background. No text, no progress indicator — shown
/// briefly at startup while the (synchronous, effectively instant) database
/// setup happens, then dismissed so the main `WindowGroup` window takes over.
///
/// This is implemented at the AppKit level (rather than as a SwiftUI
/// `WindowGroup`/view) because it needs to appear *before* SwiftUI's own
/// windows are created and manage its own lifecycle independent of the
/// scene graph.
@MainActor
enum SplashWindowController {
    private static var window: NSWindow?

    /// Whether the splash window is currently shown.
    static var isActive: Bool { window != nil }

    /// Whether `candidate` is the splash window itself (as opposed to the
    /// main SwiftUI window or any other window in the app).
    static func isSplashWindow(_ candidate: NSWindow) -> Bool { candidate === window }

    /// Creates and shows the splash window immediately, above other windows.
    static func show() {
        guard window == nil else { return }

        let side: CGFloat = 256
        let size = NSSize(width: side, height: side)
        let splash = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        splash.isReleasedWhenClosed = false
        splash.isOpaque = false
        splash.hasShadow = true
        splash.backgroundColor = .clear
        splash.level = .floating
        splash.isMovableByWindowBackground = false
        splash.ignoresMouseEvents = true

        let containerView = NSView(frame: NSRect(origin: .zero, size: size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.cornerRadius = side * 0.2237
        containerView.layer?.masksToBounds = true

        let imageView = NSImageView(frame: containerView.bounds)
        imageView.image = appIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]

        containerView.addSubview(imageView)
        splash.contentView = containerView

        splash.center()
        splash.orderFrontRegardless()

        window = splash
    }

    /// Closes the splash window, if visible.
    static func dismiss() {
        guard let splash = window else { return }
        window = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            splash.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                splash.close()
            }
        }
    }

    /// Resolves the app icon, with fallbacks so this never crashes even when
    /// running unpackaged (no bundled AppIcon) during development.
    private static func appIcon() -> NSImage? {
        if let icon = NSApp.applicationIconImage {
            return icon
        }
        if let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }
        return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "PaperReader")
    }
}
