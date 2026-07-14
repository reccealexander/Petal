import AppKit

/// Pre-main-window launch splash: a borderless, floating `NSWindow` showing
/// the animated "Pet.al" wordmark and a single "Research Now" button. The
/// splash stays up indefinitely — there is no auto-dismiss timer — until the
/// user clicks the button. The click no longer reveals the main window
/// directly: it starts a "bloom" transition in which the window turns into a
/// large transparent canvas, a flower of pink petals grows clockwise out of
/// the wordmark's period (with a yellow pistil at its center), and only when
/// the bloom completes does the stored `onResearchNow` closure run (revealing
/// the main window, whose implementation calls `dismiss()`).
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

    // MARK: Bloom transition state

    /// The closure supplied to `show(onResearchNow:)`, held until the bloom
    /// transition completes (or Reduce Motion short-circuits it). Fired
    /// exactly once via `fireResearchNow()`.
    private static var pendingResearchNow: (() -> Void)?

    /// Re-entrancy guard: once the bloom starts, further clicks are ignored.
    private static var bloomStarted = false

    /// Fire-once guard for `pendingResearchNow` (the CATransaction completion
    /// and the safety-net timer can both attempt to fire it).
    private static var hasFiredResearchNow = false

    /// Views/geometry captured at `show()` time that the bloom needs later:
    /// the title container hosting the glyph layers, the button to hide, and
    /// the resting center of the "." glyph in `titleContainer` coordinates —
    /// the anchor point the whole flower is centered on.
    private static var bloomTitleContainer: NSView?
    private static var bloomButton: NSButton?
    private static var bloomDotRest: CGPoint = .zero

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

        // Hold the reveal closure; the button starts the bloom transition and
        // the closure only runs when the bloom completes (see `beginBloom`).
        pendingResearchNow = onResearchNow
        bloomStarted = false
        hasFiredResearchNow = false
        bloomTitleContainer = titleContainer
        bloomButton = button
        bloomDotRest = dotRest

        let target = ResearchNowTarget {
            MainActor.assumeIsolated { beginBloom() }
        }
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

    // MARK: - Bloom transition

    /// Ring layout: 8 petals per ring; ring 1 starts pointing top-right (45°)
    /// and sweeps clockwise; ring 2 is interleaved (offset by half a step,
    /// 22.5°), slightly smaller and darker, and renders behind ring 1.
    private static let petalsPerRing = 8

    /// Side of the square transparent canvas the window grows to for the
    /// bloom. Half of it (260pt) comfortably contains the largest petal reach
    /// (~127pt with overshoot) and the wordmark's extent around the dot.
    private static let bloomCanvasSide: CGFloat = 520

    /// Starts the flower-bloom transition: turns the window into a large
    /// transparent canvas centered on the wordmark's "." (so only the wordmark
    /// and the flower render over the desktop), grows a first pink petal
    /// toward the top-right plus a yellow pistil out of the period, sweeps a
    /// full clockwise ring of petals, then a second interleaved ring, and —
    /// only when the whole bloom has completed — fires the stored
    /// `onResearchNow` closure to reveal the main window.
    ///
    /// Honors Reduce Motion by skipping the bloom entirely and firing the
    /// reveal promptly (the reveal path's `dismiss()` provides a short fade).
    private static func beginBloom() {
        guard !bloomStarted else { return }
        bloomStarted = true

        guard let splash = window,
              let contentView = splash.contentView,
              let rootLayer = contentView.layer,
              let titleContainer = bloomTitleContainer else {
            // Nothing sensible to animate — never strand the user on the splash.
            fireResearchNow()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fireResearchNow()
            return
        }

        // --- 1. Transparent canvas anchored on the period --------------------
        // Compute the dot's on-screen center, then instantly swap the window
        // frame for a large square canvas whose center is exactly that point.
        // The window is already fully transparent by then, so the frame change
        // itself is invisible; the subviews are shifted by the frame delta so
        // the wordmark does not move on screen. This gives the flower room to
        // radiate 360° from the dot without clipping against window bounds.
        let dotInWindow = titleContainer.convert(bloomDotRest, to: nil)
        let dotOnScreen = splash.convertPoint(toScreen: dotInWindow)
        let side = bloomCanvasSide
        let newFrame = NSRect(
            x: dotOnScreen.x - side / 2,
            y: dotOnScreen.y - side / 2,
            width: side,
            height: side
        )
        let oldOrigin = splash.frame.origin

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        splash.isMovableByWindowBackground = false
        splash.isOpaque = false
        splash.backgroundColor = .clear
        splash.hasShadow = false
        rootLayer.backgroundColor = NSColor.clear.cgColor
        bloomButton?.isHidden = true

        splash.setFrame(newFrame, display: false)
        let delta = CGPoint(x: oldOrigin.x - newFrame.origin.x,
                            y: oldOrigin.y - newFrame.origin.y)
        for subview in contentView.subviews {
            subview.setFrameOrigin(NSPoint(x: subview.frame.origin.x + delta.x,
                                           y: subview.frame.origin.y + delta.y))
        }
        CATransaction.commit()
        splash.invalidateShadow()

        // The flower's center: the dot's position expressed in the (resized)
        // content view's coordinate space — by construction the canvas center.
        let flowerCenter = contentView.convert(bloomDotRest, from: titleContainer)

        // --- 2. Build the flower ---------------------------------------------
        // Petals live in a zero-bounds container layer at the flower center,
        // inserted BELOW the wordmark so pink never obscures the glyphs; the
        // pistil is added ABOVE it so the period visually becomes the flower's
        // dark heart inside a yellow center.
        let flowerLayer = CALayer()
        flowerLayer.position = flowerCenter
        flowerLayer.bounds = .zero
        flowerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let ring1Length: CGFloat = 118
        let ring1Width: CGFloat = 48
        let ring2Length: CGFloat = 92
        let ring2Width: CGFloat = 42

        let ring1Color = NSColor.systemPink
        let ring2Color = NSColor.systemPink.blended(withFraction: 0.22, of: .black) ?? .systemPink

        let ring1Path = petalPath(length: ring1Length, width: ring1Width)
        let ring2Path = petalPath(length: ring2Length, width: ring2Width)
        let ring1Rotations = petalRotations(count: petalsPerRing, firstPetalAngleDegrees: 45)
        let ring2Rotations = petalRotations(count: petalsPerRing, firstPetalAngleDegrees: 22.5)

        // Ring 2 first so it sits behind ring 1.
        let ring2Petals = ring2Rotations.map { rotation -> CAShapeLayer in
            let petal = makePetalLayer(path: ring2Path, length: ring2Length,
                                       width: ring2Width, color: ring2Color,
                                       rotation: rotation)
            flowerLayer.addSublayer(petal)
            return petal
        }
        let ring1Petals = ring1Rotations.map { rotation -> CAShapeLayer in
            let petal = makePetalLayer(path: ring1Path, length: ring1Length,
                                       width: ring1Width, color: ring1Color,
                                       rotation: rotation)
            flowerLayer.addSublayer(petal)
            return petal
        }
        rootLayer.insertSublayer(flowerLayer, at: 0)

        // Yellow pistil: a small rounded center (yellow disc with a soft
        // orange core), drawn above the petals AND above the wordmark so the
        // "." reads as the flower's center once it blooms.
        let pistil = CALayer()
        pistil.position = flowerCenter
        pistil.bounds = .zero
        pistil.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let pistilDisc = CAShapeLayer()
        pistilDisc.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        pistilDisc.fillColor = NSColor.systemYellow.cgColor
        let pistilCore = CAShapeLayer()
        pistilCore.path = CGPath(ellipseIn: CGRect(x: -5.5, y: -5.5, width: 11, height: 11), transform: nil)
        pistilCore.fillColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        pistil.addSublayer(pistilDisc)
        pistil.addSublayer(pistilCore)
        rootLayer.addSublayer(pistil)

        // --- 3. Choreography ---------------------------------------------------
        // t 0.00–0.50  hero petal (top-right) + pistil grow out of the period
        // t 0.50–1.27  ring 1 sweeps clockwise, one petal every 75ms
        // t 1.25–1.97  ring 2 (interleaved, behind) sweeps clockwise every 60ms
        // t ~2.22      brief hold, then the stored onResearchNow fires
        let heroDuration: CFTimeInterval = 0.5
        let ring1Stagger: CFTimeInterval = 0.075
        let ring1Duration: CFTimeInterval = 0.32
        let ring2Begin: CFTimeInterval = 1.25
        let ring2Stagger: CFTimeInterval = 0.06
        let ring2Duration: CFTimeInterval = 0.30
        let bloomEnd = ring2Begin + CFTimeInterval(petalsPerRing - 1) * ring2Stagger + ring2Duration

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                // Let the completed flower register for a beat before the
                // main window appears.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { fireResearchNow() }
                }
            }
        }

        for (index, petal) in ring1Petals.enumerated() {
            let delay = index == 0 ? 0 : heroDuration + CFTimeInterval(index - 1) * ring1Stagger
            let duration = index == 0 ? heroDuration : ring1Duration
            petal.add(petalGrowAnimation(delay: delay, duration: duration), forKey: "grow")
        }
        for (index, petal) in ring2Petals.enumerated() {
            let delay = ring2Begin + CFTimeInterval(index) * ring2Stagger
            petal.add(petalGrowAnimation(delay: delay, duration: ring2Duration), forKey: "grow")
        }
        pistil.add(petalGrowAnimation(delay: 0.05, duration: heroDuration), forKey: "grow")

        CATransaction.commit()

        // Safety net: if the transaction completion is ever short-circuited
        // (layers torn down, window closed early), still reveal the main
        // window. `fireResearchNow`'s guard makes double-firing impossible.
        DispatchQueue.main.asyncAfter(deadline: .now() + bloomEnd + 0.9) {
            MainActor.assumeIsolated { fireResearchNow() }
        }
    }

    /// Fires the stored `onResearchNow` closure exactly once.
    private static func fireResearchNow() {
        guard !hasFiredResearchNow else { return }
        hasFiredResearchNow = true
        let action = pendingResearchNow
        pendingResearchNow = nil
        action?()
    }

    /// Builds one petal as a base-anchored `CAShapeLayer`: the petal path
    /// points along +y, the layer's anchor is the petal base (the point that
    /// touches the flower center), `position` is the flower center (`.zero`
    /// in the flower container), and the final orientation is baked into the
    /// model `transform` so the grow animation only drives scale/opacity.
    private static func makePetalLayer(
        path: CGPath, length: CGFloat, width: CGFloat,
        color: NSColor, rotation: CGFloat
    ) -> CAShapeLayer {
        let petal = CAShapeLayer()
        petal.path = path
        petal.fillColor = color.cgColor
        petal.bounds = CGRect(x: -width / 2, y: 0, width: width, height: length)
        petal.anchorPoint = CGPoint(x: 0.5, y: 0) // the base, path point (0,0)
        petal.position = .zero
        petal.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
        return petal
    }

    /// Returns the outline of a single flower petal as a closed `CGPath`.
    ///
    /// The path is built in a y-up (non-flipped) coordinate space: the petal's
    /// base — the point that attaches to the flower's center — sits at the
    /// origin `(0, 0)` and the tip at `(0, length)`, so the petal points along
    /// +y. The silhouette is a symmetric teardrop/leaf: softly pointed at the
    /// base, swelling to its maximum `width` at ~42% of the length, then
    /// tapering to a softly rounded-but-pointed tip. It is assembled from four
    /// cubic Bézier segments (two per side); the control points adjacent to
    /// the base, tip, and widest point sit on vertical lines so the left and
    /// right halves meet with matching tangents and no visible kinks.
    private static func petalPath(length: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()

        let halfWidth = width / 2
        let widestY = length * 0.42 // height at which the petal is widest

        // Base -> right widest point.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: halfWidth, y: widestY),
            control1: CGPoint(x: 0, y: length * 0.14),
            control2: CGPoint(x: halfWidth, y: widestY - length * 0.16)
        )
        // Right widest point -> tip.
        path.addCurve(
            to: CGPoint(x: 0, y: length),
            control1: CGPoint(x: halfWidth, y: widestY + length * 0.20),
            control2: CGPoint(x: 0, y: length - length * 0.10)
        )
        // Tip -> left widest point (mirror of the upper-right curve).
        path.addCurve(
            to: CGPoint(x: -halfWidth, y: widestY),
            control1: CGPoint(x: 0, y: length - length * 0.10),
            control2: CGPoint(x: -halfWidth, y: widestY + length * 0.20)
        )
        // Left widest point -> base (mirror of the lower-right curve).
        path.addCurve(
            to: CGPoint(x: 0, y: 0),
            control1: CGPoint(x: -halfWidth, y: widestY - length * 0.16),
            control2: CGPoint(x: 0, y: length * 0.14)
        )

        path.closeSubpath()
        return path
    }

    /// Returns the z-rotation (radians) for each of `count` petals so petal k
    /// points along direction θₖ = `firstPetalAngleDegrees` − k·(360/count)
    /// degrees (0° = +x, 90° = +y, positive = CCW). Subtracting per step makes
    /// the sequence proceed CLOCKWISE around the ring. Since an un-rotated
    /// petal points along +y (90°), the applied rotation for direction θ is
    /// (θ − 90°).
    private static func petalRotations(count: Int, firstPetalAngleDegrees: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let step = 360 / CGFloat(count)
        let degreesToRadians = CGFloat.pi / 180
        return (0..<count).map { k in
            let thetaDegrees = firstPetalAngleDegrees - CGFloat(k) * step
            return (thetaDegrees - 90) * degreesToRadians
        }
    }

    /// Grouped "grow" animation for one petal (or the pistil) whose MODEL
    /// values are already final (transform = final rotation, opacity = 1).
    /// Scale springs 0.01 → 1.08 → 1 with a gentle organic overshoot; opacity
    /// fades in over the first ~35%. `.backwards` fill keeps a staggered layer
    /// invisible until its `beginTime`, after which it animates to the
    /// already-set model values. Rotation stays baked in the model transform —
    /// the uniform "transform.scale" key path composes with it without skew.
    private static func petalGrowAnimation(delay: CFTimeInterval, duration: CFTimeInterval) -> CAAnimationGroup {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.01, 1.08, 1.0]
        scale.keyTimes = [0.0, 0.72, 1.0]
        scale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = duration * 0.35
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        return group
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
        bloomTitleContainer = nil
        bloomButton = nil
        // `pendingResearchNow`/`hasFiredResearchNow` are intentionally NOT
        // reset here: if a bloom is mid-flight when something else dismisses
        // the splash, the scheduled completion must still be able to fire the
        // reveal exactly once. `show()` re-primes all bloom state.

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
