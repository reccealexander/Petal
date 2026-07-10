import AppKit

/// Minimal pre-main-window launch splash: a borderless, floating `NSWindow`
/// showing only the app icon centered on a plain white background. No text,
/// no progress indicator — shown briefly at startup while the (synchronous,
/// effectively instant) database setup happens, then dismissed so the main
/// `WindowGroup` window takes over.
///
/// This is implemented at the AppKit level (rather than as a SwiftUI
/// `WindowGroup`/view) because it needs to appear *before* SwiftUI's own
/// windows are created and manage its own lifecycle independent of the
/// scene graph.
@MainActor
enum SplashWindowController {
    private static var window: NSWindow?

    /// Creates and shows the splash window immediately, above other windows.
    static func show() {
        guard window == nil else { return }

        let size = NSSize(width: 360, height: 360)
        let splash = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        splash.isReleasedWhenClosed = false
        splash.isOpaque = true
        splash.hasShadow = true
        splash.backgroundColor = .white
        splash.level = .floating
        splash.isMovableByWindowBackground = false
        splash.ignoresMouseEvents = true

        let containerView = NSView(frame: NSRect(origin: .zero, size: size))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.white.cgColor

        let iconSize = NSSize(width: 200, height: 200)
        let imageView = NSImageView(frame: NSRect(
            x: (size.width - iconSize.width) / 2,
            y: (size.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        ))
        imageView.image = appIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]

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
            context.duration = 0.2
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
