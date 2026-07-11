import AppKit

/// Pre-main-window launch splash: a borderless, floating `NSWindow` showing
/// the app icon plus a single "Research Now" button. The splash stays up
/// indefinitely — there is no auto-dismiss timer — until the user clicks the
/// button, at which point the supplied `onResearchNow` closure runs (revealing
/// the main window) and the caller is responsible for calling `dismiss()`.
///
/// This is implemented at the AppKit level (rather than as a SwiftUI
/// `WindowGroup`/view) because it needs to appear *before* SwiftUI's own
/// windows are created and manage its own lifecycle independent of the
/// scene graph.
@MainActor
enum SplashWindowController {
    private static var window: NSWindow?

    /// Strong reference to the button's target/action shim so it isn't
    /// deallocated out from under the (unretained) NSButton.target link.
    private static var researchNowTarget: ResearchNowTarget?

    /// Whether the splash window is currently shown.
    static var isActive: Bool { window != nil }

    /// Whether `candidate` is the splash window itself (as opposed to the
    /// main SwiftUI window or any other window in the app).
    static func isSplashWindow(_ candidate: NSWindow) -> Bool { candidate === window }

    /// Creates and shows the splash window immediately, above other windows.
    /// The window has no timer — it stays up until the user clicks
    /// "Research Now", at which point `onResearchNow` is invoked.
    static func show(onResearchNow: @escaping () -> Void) {
        guard window == nil else { return }

        let windowSize = NSSize(width: 300, height: 340)
        let splash = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        splash.isReleasedWhenClosed = false
        splash.isOpaque = true
        splash.hasShadow = true
        splash.backgroundColor = .windowBackgroundColor
        splash.level = .floating
        splash.isMovableByWindowBackground = true
        // Must NOT ignore mouse events — the "Research Now" button needs to
        // receive clicks.

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Icon, clipped to a rounded square so it still reads as the app
        // icon shape, centered near the top of the window.
        let iconSide: CGFloat = 170
        let iconOrigin = NSPoint(
            x: (windowSize.width - iconSide) / 2,
            y: windowSize.height - 34 - iconSide
        )
        let iconContainer = NSView(frame: NSRect(origin: iconOrigin, size: NSSize(width: iconSide, height: iconSide)))
        iconContainer.wantsLayer = true
        iconContainer.layer?.backgroundColor = NSColor.clear.cgColor
        iconContainer.layer?.cornerRadius = iconSide * 0.2237
        iconContainer.layer?.masksToBounds = true

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: NSSize(width: iconSide, height: iconSide)))
        imageView.image = appIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.autoresizingMask = [.width, .height]
        iconContainer.addSubview(imageView)

        // "Research Now" button, centered below the icon.
        let buttonSize = NSSize(width: 160, height: 34)
        let buttonOrigin = NSPoint(
            x: (windowSize.width - buttonSize.width) / 2,
            y: iconOrigin.y - 32 - buttonSize.height
        )
        let button = NSButton(frame: NSRect(origin: buttonOrigin, size: buttonSize))
        button.title = "Research Now"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .medium)

        let target = ResearchNowTarget(action: onResearchNow)
        researchNowTarget = target
        button.target = target
        button.action = #selector(ResearchNowTarget.invoke)
        button.keyEquivalent = "\r"

        contentView.addSubview(iconContainer)
        contentView.addSubview(button)
        splash.contentView = contentView

        splash.center()
        splash.orderFrontRegardless()
        splash.makeKeyAndOrderFront(nil)
        splash.makeFirstResponder(button)

        window = splash
    }

    /// Closes the splash window, if visible.
    static func dismiss() {
        guard let splash = window else { return }
        window = nil
        researchNowTarget = nil

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            splash.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                splash.close()
            }
        }
    }

    /// Resolves the app icon at full resolution. `NSApp.applicationIconImage`
    /// can hand back a downscaled/cached representation, so we prefer loading
    /// the high-res source PNG straight out of the app bundle's Resources
    /// (copied there by `scripts/package_app.sh`) and only fall back to the
    /// system-provided icon (or an SF Symbol) when that's unavailable, e.g.
    /// during an unpackaged `swift run` debug launch.
    private static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "EasyReader_icon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        if let icon = NSApp.applicationIconImage {
            return icon
        }
        if let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }
        return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "PaperReader")
    }

    /// Small `@objc` target/action shim so the "Research Now" button can
    /// invoke a plain Swift closure.
    private final class ResearchNowTarget: NSObject {
        private let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func invoke() {
            action()
        }
    }
}
