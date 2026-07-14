import AppKit

/// Pre-main-window launch splash: a borderless, floating `NSWindow` showing
/// the animated "Pet.al" wordmark and a single "Research Now" button. The
/// splash stays up indefinitely — there is no auto-dismiss timer — until the
/// user clicks the button, at which point the supplied `onResearchNow` closure
/// runs (revealing the main window) and the caller is responsible for calling
/// `dismiss()`.
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

        // --- Title geometry --------------------------------------------------
        // Render the "Pet.al" wordmark as three independent glyph layers —
        // "Pet", a static centered ".", and "al" — so the two halves can roll
        // in from opposite edges and meet at the dot.
        let font = titleFont(ofSize: 64)
        let titleColor = NSColor.labelColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let petLayer = makeGlyphLayer("Pet", font: font, color: titleColor, scale: scale)
        let dotLayer = makeGlyphLayer(".", font: font, color: titleColor, scale: scale)
        let alLayer = makeGlyphLayer("al", font: font, color: titleColor, scale: scale)

        let petW = petLayer.bounds.width
        let dotW = dotLayer.bounds.width
        let alW = alLayer.bounds.width
        let glyphH = max(petLayer.bounds.height, dotLayer.bounds.height, alLayer.bounds.height)

        // --- Window layout (bottom-up) --------------------------------------
        let windowWidth: CGFloat = 300
        let topMargin: CGFloat = 44
        let titleHeight = ceil(glyphH) + 4
        let gapTitleButton: CGFloat = 26
        let buttonHeight: CGFloat = 34
        let bottomMargin: CGFloat = 36

        let windowHeight = topMargin + titleHeight + gapTitleButton + buttonHeight + bottomMargin
        let windowSize = NSSize(width: windowWidth, height: windowHeight)

        let titleOriginY = windowHeight - topMargin - titleHeight
        let buttonOriginY = titleOriginY - gapTitleButton - buttonHeight

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

        // Title container spanning the full window width; the glyph layers are
        // positioned by their centers within it. A layer-backed, non-flipped
        // NSView gives us a y-up coordinate system where a positive
        // `transform.rotation.z` is counter-clockwise.
        let titleContainer = NSView(frame: NSRect(x: 0, y: titleOriginY, width: windowWidth, height: titleHeight))
        titleContainer.wantsLayer = true
        titleContainer.layer?.backgroundColor = NSColor.clear.cgColor

        // Resting (final) center positions. The block "Pet" + "." + "al" is
        // centered horizontally; all three share the vertical center.
        let totalW = petW + dotW + alW
        let leftX = (windowWidth - totalW) / 2
        let centerY = titleHeight / 2
        let petRest = CGPoint(x: leftX + petW / 2, y: centerY)
        let dotRest = CGPoint(x: leftX + petW + dotW / 2, y: centerY)
        let alRest = CGPoint(x: leftX + petW + dotW + alW / 2, y: centerY)

        // Set the model layers to their final state up front; the roll-in is
        // added as a temporary animation from off-screen back to these values.
        petLayer.position = petRest
        dotLayer.position = dotRest
        alLayer.position = alRest

        titleContainer.layer?.addSublayer(petLayer)
        titleContainer.layer?.addSublayer(dotLayer)
        titleContainer.layer?.addSublayer(alLayer)

        // "Research Now" button, centered below the title.
        let buttonSize = NSSize(width: 160, height: buttonHeight)
        let buttonOrigin = NSPoint(x: (windowWidth - buttonSize.width) / 2, y: buttonOriginY)
        let button = NSButton(frame: NSRect(origin: buttonOrigin, size: buttonSize))
        button.title = "Research Now"
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .medium)

        let target = ResearchNowTarget(action: onResearchNow)
        researchNowTarget = target
        button.target = target
        button.action = #selector(ResearchNowTarget.invoke)
        button.keyEquivalent = "\r"

        contentView.addSubview(titleContainer)
        contentView.addSubview(button)
        splash.contentView = contentView

        splash.center()
        splash.orderFrontRegardless()
        splash.makeKeyAndOrderFront(nil)
        splash.makeFirstResponder(button)

        window = splash

        // Kick the roll-in animation off now that the window is on screen.
        animateTitleIn(
            pet: petLayer, dot: dotLayer, al: alLayer,
            petRest: petRest, alRest: alRest,
            titleHeight: titleHeight, windowWidth: windowWidth
        )
    }

    /// Animates the two wordmark halves rolling in from opposite window edges
    /// to meet at the static centered ".". "Pet" enters from the left rolling
    /// clockwise; "al" enters from the right rolling counter-clockwise. Each
    /// roll couples a horizontal translation with a rotation whose magnitude is
    /// the travel distance divided by an effective wheel radius, so the letters
    /// read as wheels rather than sliding tiles.
    ///
    /// Honors Reduce Motion by skipping the roll and gently fading the title in
    /// at its resting position instead.
    private static func animateTitleIn(
        pet: CATextLayer, dot: CATextLayer, al: CATextLayer,
        petRest: CGPoint, alRest: CGPoint,
        titleHeight: CGFloat, windowWidth: CGFloat
    ) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if reduceMotion {
            // Quick, motion-free fade so the title still "arrives".
            for layer in [pet, dot, al] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.3
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fadeIn")
            }
            return
        }

        let duration: CFTimeInterval = 0.75
        let ease = CAMediaTimingFunction(name: .easeOut)
        // Effective rolling radius: half the glyph band. angle = distance / r.
        let radius = max(titleHeight / 2, 1)

        // "Pet": starts fully off the LEFT edge, rolls right (clockwise → the
        // angle unwinds from +mag down to 0).
        let petStartX = -pet.bounds.width / 2 - 30
        let petDistance = petRest.x - petStartX
        addRoll(to: pet, fromX: petStartX, toX: petRest.x,
                startAngle: petDistance / radius, duration: duration, timing: ease)

        // "al": starts fully off the RIGHT edge, rolls left (counter-clockwise
        // → the angle winds from -mag up to 0).
        let alStartX = windowWidth + al.bounds.width / 2 + 30
        let alDistance = alStartX - alRest.x
        addRoll(to: al, fromX: alStartX, toX: alRest.x,
                startAngle: -(alDistance / radius), duration: duration, timing: ease)

        // The "." is a static center anchor; fade it in over the first part of
        // the roll so it "lands" roughly as the halves converge on it.
        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 0
        dotFade.toValue = 1
        dotFade.duration = duration * 0.5
        dotFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        dot.add(dotFade, forKey: "dotFade")
    }

    /// Adds a coupled translation + rotation "roll" animation to `layer`. The
    /// layer's model values are assumed to already be at their resting state
    /// (final x, rotation 0); `.backwards` fill makes it appear at the start
    /// pose before the animation begins.
    private static func addRoll(
        to layer: CALayer,
        fromX: CGFloat, toX: CGFloat,
        startAngle: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) {
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = fromX
        move.toValue = toX

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = startAngle
        spin.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [move, spin]
        group.duration = duration
        group.timingFunction = timing
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "rollIn")
    }

    /// Builds the wordmark font. We approximate *Nature* magazine's bespoke,
    /// proprietary wordmark — a heavy, high-contrast Didone serif — with the
    /// closest macOS-bundled face, `Didot-Bold`. A graceful fallback chain
    /// (Bodoni 72 Bold → Charter Black → a `.serif`-design system font →
    /// bold system font) keeps this robust if a face is ever unavailable; no
    /// named font is force-unwrapped.
    ///
    /// If a licensed Nature-style font is ever bundled into Resources, register
    /// it and prefer it at the head of this chain.
    private static func titleFont(ofSize size: CGFloat) -> NSFont {
        if let f = NSFont(name: "Didot-Bold", size: size) { return f }
        if let f = NSFont(name: "BodoniSvtyTwoITCTT-Bold", size: size) { return f }
        if let f = NSFont(name: "Charter-Black", size: size) { return f }
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        if let serif = base.fontDescriptor.withDesign(.serif),
           let f = NSFont(descriptor: serif, size: size) {
            return f
        }
        return base
    }

    /// Creates a center-anchored `CATextLayer` sized to `text` in `font`, ready
    /// to be positioned by its center and rotated about that center.
    private static func makeGlyphLayer(_ text: String, font: NSFont, color: NSColor, scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = (text as NSString).size(withAttributes: [.font: font])
        layer.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + 2, height: ceil(size.height))
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.alignmentMode = .center
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.contentsScale = scale
        return layer
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
