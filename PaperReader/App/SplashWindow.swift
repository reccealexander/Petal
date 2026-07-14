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
    /// the title container hosting the glyph layers, the button to hide, the
    /// "." glyph's true ink center in `titleContainer` coordinates (the anchor
    /// the whole flower + pistil are centered on), and the visible diameter of
    /// the "." ink (the pistil's starting size, so it grows out of the period).
    private static var bloomTitleContainer: NSView?
    private static var bloomButton: NSButton?
    private static var bloomDotAnchor: CGPoint = .zero
    private static var bloomDotDiameter: CGFloat = 6

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
        // Render the wordmark as four independent glyph layers — "P", "et",
        // "al", and a trailing "." — so they can first read as the academic
        // citation "P et al." (spaced apart) and then slide together into the
        // single word "Petal." The "." is at the RIGHT end of the wordmark and
        // becomes the flower's center when the bloom begins.
        let font = titleFont(ofSize: 64)
        let titleColor = NSColor.labelColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let pLayer = makeGlyphLayer("P", font: font, color: titleColor, scale: scale)
        let etLayer = makeGlyphLayer("et", font: font, color: titleColor, scale: scale)
        let alLayer = makeGlyphLayer("al", font: font, color: titleColor, scale: scale)
        let dotLayer = makeGlyphLayer(".", font: font, color: titleColor, scale: scale)

        let pW = pLayer.bounds.width
        let etW = etLayer.bounds.width
        let alW = alLayer.bounds.width
        let dotW = dotLayer.bounds.width
        let glyphH = max(max(pLayer.bounds.height, etLayer.bounds.height),
                         max(alLayer.bounds.height, dotLayer.bounds.height))

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
        // NSView gives us a y-up coordinate system whose coordinates match the
        // sublayer coordinate space one-to-one.
        let titleContainer = NSView(frame: NSRect(x: 0, y: titleOriginY, width: windowWidth, height: titleHeight))
        titleContainer.wantsLayer = true
        titleContainer.layer?.backgroundColor = NSColor.clear.cgColor

        // Resting (closed) center positions. The block "P"+"et"+"al"+"." is
        // centered horizontally; all four share the vertical center. This is
        // the final "Petal." layout, and where the layers live once the intro
        // slide completes — so the "." resting center is the bloom anchor.
        let totalW = pW + etW + alW + dotW
        let leftX = (windowWidth - totalW) / 2
        let centerY = titleHeight / 2
        let pRest = CGPoint(x: leftX + pW / 2, y: centerY)
        let etRest = CGPoint(x: leftX + pW + etW / 2, y: centerY)
        let alRest = CGPoint(x: leftX + pW + etW + alW / 2, y: centerY)
        let dotRest = CGPoint(x: leftX + pW + etW + alW + dotW / 2, y: centerY)

        // Spaced ("P et al.") start positions. Inserting a gap after "P" and
        // after "et" pushes "P" left by one gap and "al"+"." right by one gap,
        // while "et" — the pivot — stays put; the block stays centered.
        let intronGap: CGFloat = 26
        let pStart = CGPoint(x: pRest.x - intronGap, y: centerY)
        let etStart = etRest
        let alStart = CGPoint(x: alRest.x + intronGap, y: centerY)
        let dotStart = CGPoint(x: dotRest.x + intronGap, y: centerY)

        // Model layers rest at their CLOSED positions; the intro adds a
        // temporary slide from the spaced start positions back to these.
        pLayer.position = pRest
        etLayer.position = etRest
        alLayer.position = alRest
        dotLayer.position = dotRest

        titleContainer.layer?.addSublayer(pLayer)
        titleContainer.layer?.addSublayer(etLayer)
        titleContainer.layer?.addSublayer(alLayer)
        titleContainer.layer?.addSublayer(dotLayer)

        // The bloom anchor is the "." glyph's true INK center, not the text
        // layer's bounds center: a "." sits low on the baseline, so the layer
        // center is well above the visible dot. Offsetting to the ink center
        // keeps the flower + pistil exactly on the period.
        let dotInkOffset = dotInkCenterOffset(font: font, layerHeight: dotLayer.bounds.height)
        bloomDotAnchor = CGPoint(x: dotRest.x + dotInkOffset.x, y: dotRest.y + dotInkOffset.y)
        bloomDotDiameter = dotInkOffset.diameter

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

        // Kick the "P et al." → "Petal." intro off now that the window is up.
        animateTitleIn(
            layers: [pLayer, etLayer, alLayer, dotLayer],
            startPositions: [pStart, etStart, alStart, dotStart],
            restPositions: [pRest, etRest, alRest, dotRest]
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

    /// Starts the flower-bloom transition. On click the letters vanish at once,
    /// leaving only the period, which (A) slides from the end of "Petal." to the
    /// window's horizontal center a little below the text line, then (B) grows
    /// and turns yellow in its own beat to become the pistil, after which (C)
    /// the petals bloom: a hero petal toward the top-right, a full clockwise
    /// ring, then a second interleaved ring flowing straight out of the first
    /// with no pause. The window becomes a large transparent canvas centered on
    /// that recentered flower point so the petals have 360° of room. Only when
    /// the whole bloom completes does the stored `onResearchNow` closure fire.
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

        // --- 1. Transparent canvas centered on the flower point --------------
        // The flower does NOT bloom where the period sits (the right end of
        // "Petal."). Instead the period first slides to the window's HORIZONTAL
        // CENTER, a little BELOW the text line, and blooms there. Compute both
        // the period's current on-screen center and that recentered target,
        // then swap the window for a large transparent square canvas centered
        // on the target so the flower has 360° of room without clipping.
        let originalWidth = contentView.bounds.width
        let periodInWindow = titleContainer.convert(bloomDotAnchor, to: nil)
        let flowerDrop: CGFloat = 30 // sit a little below the text line
        let targetInWindow = CGPoint(x: originalWidth / 2,
                                     y: periodInWindow.y - flowerDrop)
        let periodOnScreen = splash.convertPoint(toScreen: periodInWindow)
        let targetOnScreen = splash.convertPoint(toScreen: targetInWindow)

        let side = bloomCanvasSide
        let newFrame = NSRect(
            x: targetOnScreen.x - side / 2,
            y: targetOnScreen.y - side / 2,
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
        // The letters ("P", "et", "al") and the text "." vanish at once — only
        // the period lives on, reborn as the pistil disc, which is spawned at
        // the period's old on-screen spot and then slides to the flower center.
        titleContainer.isHidden = true

        splash.setFrame(newFrame, display: false)
        let delta = CGPoint(x: oldOrigin.x - newFrame.origin.x,
                            y: oldOrigin.y - newFrame.origin.y)
        for subview in contentView.subviews {
            subview.setFrameOrigin(NSPoint(x: subview.frame.origin.x + delta.x,
                                           y: subview.frame.origin.y + delta.y))
        }
        CATransaction.commit()
        splash.invalidateShadow()

        // Both key points expressed in the resized content view's coordinates
        // (derived from screen coords + the new frame origin, independent of
        // any autoresizing): the flower center is the canvas center, and the
        // pistil's translate starts from the period's former on-screen spot.
        let flowerCenter = CGPoint(x: targetOnScreen.x - newFrame.minX,
                                   y: targetOnScreen.y - newFrame.minY)
        let periodStart = CGPoint(x: periodOnScreen.x - newFrame.minX,
                                  y: periodOnScreen.y - newFrame.minY)

        // --- 2. Build the flower ---------------------------------------------
        // Petals live in a zero-bounds container at the flower center, inserted
        // BELOW everything; the pistil is added ABOVE so the recentered period
        // becomes the flower's yellow center.
        let flowerLayer = CALayer()
        flowerLayer.position = flowerCenter
        flowerLayer.bounds = .zero
        flowerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        // All 16 petals are identical in size; ring 2 differs only by its
        // half-step angular interleave and by rendering behind ring 1.
        let ring1Length: CGFloat = 118
        let ring1Width: CGFloat = 46
        let ring2Length: CGFloat = ring1Length
        let ring2Width: CGFloat = ring1Width

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

        // --- The period BECOMES the pistil -----------------------------------
        // A container that starts dot-sized and dark (like the ".") at the
        // period's former spot. It (A) slides to the flower center, then (B)
        // grows + turns yellow in its own smooth beat, then (C) the petals
        // bloom. Its model position is the flower center; a translate animation
        // carries it there from `periodStart`.
        let pistilRadius: CGFloat = 15
        let pistil = CALayer()
        pistil.position = flowerCenter
        pistil.bounds = .zero
        pistil.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        let pistilDisc = CAShapeLayer()
        pistilDisc.path = CGPath(ellipseIn: CGRect(x: -pistilRadius, y: -pistilRadius,
                                                   width: 2 * pistilRadius, height: 2 * pistilRadius),
                                 transform: nil)
        pistilDisc.fillColor = NSColor.systemYellow.cgColor // final color
        pistil.addSublayer(pistilDisc)

        // Rotating detail (stamen ring + core) that appears as the disc reaches
        // full size so the growth reads as a real pistil, not just a disc.
        let detail = CALayer()
        detail.bounds = .zero
        detail.position = .zero
        let stamenCount = 7
        for i in 0..<stamenCount {
            let angle = CGFloat(i) / CGFloat(stamenCount) * 2 * .pi
            let ring = pistilRadius * 0.52
            let tip: CGFloat = 2.6
            let stamen = CAShapeLayer()
            stamen.path = CGPath(ellipseIn: CGRect(x: cos(angle) * ring - tip,
                                                   y: sin(angle) * ring - tip,
                                                   width: 2 * tip, height: 2 * tip),
                                 transform: nil)
            stamen.fillColor = NSColor.systemOrange.cgColor
            detail.addSublayer(stamen)
        }
        let core = CAShapeLayer()
        core.path = CGPath(ellipseIn: CGRect(x: -5, y: -5, width: 10, height: 10), transform: nil)
        core.fillColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        detail.addSublayer(core)
        pistil.addSublayer(detail)
        rootLayer.addSublayer(pistil)

        // --- 3. Choreography (sequenced) -------------------------------------
        //  t 0.00–0.40  the period slides from its spot to the flower center
        //  t 0.40–0.88  it grows + turns yellow (own beat) → pistil, detail in
        //  t 0.88–…     petals bloom: hero petal (top-right), ring 1 clockwise,
        //               then ring 2 interleaved with NO gap (same cadence)
        //  end + 0.25   brief hold, then the stored onResearchNow fires
        let translateDuration: CFTimeInterval = 0.40
        let growBegin: CFTimeInterval = translateDuration
        let growDuration: CFTimeInterval = 0.48
        let petalsBegin: CFTimeInterval = growBegin + growDuration // 0.88

        let heroPetalDuration: CFTimeInterval = 0.40
        let ring1Stagger: CFTimeInterval = 0.06
        let ring1Duration: CFTimeInterval = 0.28
        // Ring 2 continues the exact same cadence right after ring 1's last
        // petal starts — no pause between the rings.
        let ring2Begin: CFTimeInterval = petalsBegin + heroPetalDuration
            + CFTimeInterval(petalsPerRing) * ring1Stagger
        let ring2Stagger: CFTimeInterval = 0.05
        let ring2Duration: CFTimeInterval = 0.28
        let bloomEnd = ring2Begin + CFTimeInterval(petalsPerRing - 1) * ring2Stagger + ring2Duration

        let now = CACurrentMediaTime()

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

        // Ring 1: hero petal grows first; the rest fan out clockwise only once
        // the hero has reached full size.
        for (index, petal) in ring1Petals.enumerated() {
            let delay = index == 0
                ? petalsBegin
                : petalsBegin + heroPetalDuration + CFTimeInterval(index - 1) * ring1Stagger
            let duration = index == 0 ? heroPetalDuration : ring1Duration
            petal.add(petalGrowAnimation(delay: delay, duration: duration), forKey: "grow")
        }
        // Ring 2: interleaved, behind, flowing straight out of ring 1.
        for (index, petal) in ring2Petals.enumerated() {
            let delay = ring2Begin + CFTimeInterval(index) * ring2Stagger
            petal.add(petalGrowAnimation(delay: delay, duration: ring2Duration), forKey: "grow")
        }

        // (A) Slide the period to the flower center (x and y animated
        // explicitly so the value boxing is unambiguous).
        let slideX = CABasicAnimation(keyPath: "position.x")
        slideX.fromValue = periodStart.x
        slideX.toValue = flowerCenter.x
        let slideY = CABasicAnimation(keyPath: "position.y")
        slideY.fromValue = periodStart.y
        slideY.toValue = flowerCenter.y
        let slide = CAAnimationGroup()
        slide.animations = [slideX, slideY]
        slide.duration = translateDuration
        slide.beginTime = now
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.fillMode = .backwards
        slide.isRemovedOnCompletion = true
        pistil.add(slide, forKey: "slide")

        // (B) Grow + spin, held dot-sized (via backwards fill) until the slide
        // finishes, so growth is its own beat after the translate.
        let startScale = max(bloomDotDiameter / (2 * pistilRadius), 0.1)
        let pistilGrow = CAKeyframeAnimation(keyPath: "transform.scale")
        pistilGrow.values = [startScale, 1.06, 1.0]
        pistilGrow.keyTimes = [0.0, 0.78, 1.0]
        pistilGrow.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        let pistilSpin = CABasicAnimation(keyPath: "transform.rotation.z")
        pistilSpin.fromValue = -CGFloat.pi * 0.9 // unwinds to 0 as it grows
        pistilSpin.toValue = 0
        let pistilMove = CAAnimationGroup()
        pistilMove.animations = [pistilGrow, pistilSpin]
        pistilMove.duration = growDuration
        pistilMove.beginTime = now + growBegin
        pistilMove.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pistilMove.fillMode = .backwards
        pistilMove.isRemovedOnCompletion = true
        pistil.add(pistilMove, forKey: "grow")

        // Disc color: dark (the period's ink) → yellow, during the grow beat.
        let colorMorph = CABasicAnimation(keyPath: "fillColor")
        colorMorph.fromValue = NSColor.labelColor.cgColor
        colorMorph.toValue = NSColor.systemYellow.cgColor
        colorMorph.duration = growDuration * 0.85
        colorMorph.beginTime = now + growBegin
        colorMorph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        colorMorph.fillMode = .backwards
        colorMorph.isRemovedOnCompletion = true
        pistilDisc.add(colorMorph, forKey: "colorMorph")

        // Stamen ring + core fade in as the disc reaches full size.
        let detailFade = CABasicAnimation(keyPath: "opacity")
        detailFade.fromValue = 0
        detailFade.toValue = 1
        detailFade.duration = growDuration * 0.55
        detailFade.beginTime = now + growBegin + growDuration * 0.45
        detailFade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        detailFade.fillMode = .backwards
        detailFade.isRemovedOnCompletion = true
        detail.add(detailFade, forKey: "detailFade")

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
    ///
    /// Each petal carries a small, soft drop shadow so overlapping petals read
    /// as distinct. The shadow is set on the layer's `shadowPath` (the petal
    /// outline) so it stays cheap and crisp.
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

        // Subtle per-petal separation shadow: soft, small, barely offset.
        petal.shadowColor = NSColor.black.cgColor
        petal.shadowOpacity = 0.22
        petal.shadowRadius = 2.5
        petal.shadowOffset = CGSize(width: 0, height: -1.5)
        petal.shadowPath = path
        return petal
    }

    /// A simple oval petal: an ellipse `width` wide and `length` tall, with its
    /// base touching the origin (0,0) and pointing up toward +y. Coordinate
    /// space is y-up (non-flipped CALayer).
    private static func petalPath(length: CGFloat, width: CGFloat) -> CGPath {
        let rect = CGRect(x: -width / 2, y: 0, width: width, height: length)
        return CGPath(ellipseIn: rect, transform: nil)
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

    /// Intro animation: the four glyph layers appear SPACED APART as the
    /// academic citation "P et al.", hold for ~1s, then smoothly slide together
    /// (closing the gaps) into the single word "Petal.". Each layer's model
    /// position is already at its closed rest; a `position.x` animation with
    /// `.backwards` fill holds it at the spaced start during the hold, then
    /// eases it home. A brief opacity fade at t0 lets the wordmark "arrive".
    ///
    /// Honors Reduce Motion by skipping the hold + slide and simply fading the
    /// wordmark in at its final "Petal." positions.
    private static func animateTitleIn(
        layers: [CATextLayer],
        startPositions: [CGPoint],
        restPositions: [CGPoint]
    ) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if reduceMotion {
            for layer in layers {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = 0.3
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fadeIn")
            }
            return
        }

        let fadeDuration: CFTimeInterval = 0.35
        let holdDuration: CFTimeInterval = 1.0
        let slideDuration: CFTimeInterval = 0.55
        let now = CACurrentMediaTime()
        let slideEase = CAMediaTimingFunction(name: .easeInEaseOut)

        for (index, layer) in layers.enumerated() {
            let start = startPositions[index]
            let rest = restPositions[index]

            // Fade the whole wordmark in at t0 (over the spaced layout).
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.beginTime = now
            fade.fillMode = .backwards
            layer.add(fade, forKey: "fadeIn")

            // Slide from spaced start to closed rest, after the hold. `.et`
            // (start == rest) yields a no-op slide, which is correct — it is
            // the pivot the others close toward.
            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = start.x
            slide.toValue = rest.x
            slide.duration = slideDuration
            slide.timingFunction = slideEase
            slide.beginTime = now + fadeDuration + holdDuration
            slide.fillMode = .backwards
            slide.isRemovedOnCompletion = true
            layer.add(slide, forKey: "slideTogether")
        }
    }

    /// Computes the offset from a "." text layer's bounds center to the visible
    /// dot ink's center, plus the dot's ink diameter. A period glyph sits low
    /// on the baseline, so a full-line-height `CATextLayer`'s geometric center
    /// is well above the ink; the returned `y` (typically negative in the y-up
    /// layer space) shifts an anchor down onto the actual dot. `x` is ~0 since
    /// the glyph is horizontally centered by the layer's `.center` alignment.
    private static func dotInkCenterOffset(
        font: NSFont, layerHeight: CGFloat
    ) -> (x: CGFloat, y: CGFloat, diameter: CGFloat) {
        let ctFont = font as CTFont
        var character: UniChar = 46 // "."
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) else {
            return (0, 0, 6)
        }
        var g = glyph
        let inkBounds = CTFontGetBoundingRectsForGlyphs(ctFont, .default, &g, nil, 1)
        let ascent = CTFontGetAscent(ctFont)
        // Baseline height from the layer bottom (y-up): the single text line's
        // ascent hangs from the layer top, so baseline = height - ascent.
        let baselineY = layerHeight - ascent
        let inkCenterY = baselineY + inkBounds.midY
        let dy = inkCenterY - layerHeight / 2
        let diameter = max(inkBounds.width, inkBounds.height)
        return (0, dy, diameter)
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
