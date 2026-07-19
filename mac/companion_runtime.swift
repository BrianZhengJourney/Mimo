import Cocoa
import QuartzCore

// The companion runtime: one clock, one world snapshot, one pass per frame.
//
// Structure follows Shimeji's three-phase tick — sample the world once, advance
// every companion's logic, then commit presentation — so all companions see an
// identical world and none observes another mid-update. The clock is a
// CVDisplayLink rather than a Timer, which removes the two unsynchronised
// animation clocks the current implementation runs during victoryWalk (a CSS
// compositor animation plus a 60Hz Timer calling setFrameOrigin).
//
// Physics lives in companion_physics.swift and is already unit tested; this
// file is the part that has to touch AppKit, so it stays as thin as it can.

enum CompanionMotionState: Equatable {
    case grounded(SurfaceID)
    case airborne
    case held
}

/// One companion: where it is, what it is doing, and what it looks like.
final class Companion {
    let sprite: CompanionSprite
    let displayHeight: CGFloat
    let layer: CALayer

    var anchor: CGPoint
    var state: CompanionMotionState = .airborne
    var integrator = CompanionIntegrator()
    var spring = DragSpring()
    var facingRight = false
    var frameIndex = 0

    /// Cursor-to-anchor offset captured at grab time, so a companion does not
    /// snap its centre to the pointer the instant you touch it.
    var grabOffset = CGVector.zero
    /// Seconds since landing, driving the squash-and-stretch recovery.
    var landingElapsed: CGFloat = .greatestFiniteMagnitude

    init(sprite: CompanionSprite, displayHeight: CGFloat, anchor: CGPoint) {
        self.sprite = sprite
        self.displayHeight = displayHeight
        self.anchor = anchor
        layer = CALayer()
        layer.actions = ["position": NSNull(), "bounds": NSNull(),
                         "contents": NSNull(), "transform": NSNull()]
        layer.contents = sprite.frame(0).image
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    var currentFrame: CompanionFrame { sprite.frame(frameIndex) }

    /// On-screen rect in global (screen) coordinates.
    func screenRect() -> CGRect {
        currentFrame.rect(anchoredAt: anchor, displayHeight: displayHeight, cellSize: sprite.cellSize)
    }

    func isOpaque(atScreenPoint point: CGPoint) -> Bool {
        currentFrame.isOpaque(at: point, in: screenRect())
    }
}

final class CompanionRuntime {
    /// How tall a companion renders. Matches the raster familiar size the
    /// current overlay uses so the change of host does not change its size.
    static let defaultDisplayHeight: CGFloat = 240
    /// Landing squash: peak compression and how long the recovery runs.
    static let squashDepth: CGFloat = 0.22
    static let squashDuration: CGFloat = 0.28

    private var windows: [CGDirectDisplayID: CompanionLayerWindow] = [:]
    private var companions: [Companion] = []
    private var cursor = CursorTracker(position: NSEvent.mouseLocation)
    private var displayLink: CADisplayLink?
    private weak var clockHost: CompanionHostView?
    private var lastTimestamp: CFTimeInterval = 0
    private var held: Companion?

    /// Raised on a click that was a click, not a drag.
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var pressAnchor: CGPoint = .zero
    private var pressWasDrag = false

    var isEmpty: Bool { companions.isEmpty }

    // MARK: - Lifecycle

    func start() {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startClock()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        clockHost = nil
        NotificationCenter.default.removeObserver(self)
        companions.forEach { $0.layer.removeFromSuperlayer() }
        companions.removeAll()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    @objc private func screensChanged() {
        rebuildWindows()
        // A display can vanish while a companion is standing on it; drop anyone
        // now outside every work area back into the primary screen rather than
        // stranding them off-canvas.
        let world = worldSurfaces()
        for companion in companions where !anyDisplayContains(companion.anchor) {
            companion.anchor = CGPoint(x: world.bounds.midX, y: world.bounds.midY)
            companion.state = .airborne
            companion.integrator.velocity = .zero
        }
    }

    private func rebuildWindows() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            if let existing = windows[id] {
                existing.syncFrame(to: screen)
            } else {
                let window = CompanionLayerWindow(screen: screen)
                window.hostView.onMouseDown = { [weak self] point in self?.handleMouseDown(at: point) }
                window.hostView.onRightMouseDown = { [weak self] _ in self?.onRightClick?() }
                window.hostView.updateScale(screen.backingScaleFactor)
                windows[id] = window
            }
        }
        for (id, window) in windows where !seen.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        reattachLayers()
        if clockHost == nil || clockHost?.window == nil {
            displayLink?.invalidate()
            displayLink = nil
            startClock()
        }
    }

    /// Every companion renders into the window for whichever display it is on.
    private func reattachLayers() {
        for companion in companions {
            guard let window = window(containing: companion.anchor) ?? windows.values.first else { continue }
            if companion.layer.superlayer !== window.hostView.layer {
                companion.layer.removeFromSuperlayer()
                window.hostView.layer?.addSublayer(companion.layer)
                companion.layer.contentsScale = window.backingScaleFactor
            }
        }
    }

    private func window(containing point: CGPoint) -> CompanionLayerWindow? {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            if let id = screen.displayID { return windows[id] }
        }
        return nil
    }

    private func anyDisplayContains(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) }
    }

    // MARK: - Population

    func spawn(sprite: CompanionSprite, at anchor: CGPoint? = nil) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let start = anchor ?? CGPoint(x: visible.maxX - 140, y: visible.minY + 260)
        let companion = Companion(sprite: sprite,
                                  displayHeight: Self.defaultDisplayHeight,
                                  anchor: start)
        companions.append(companion)
        reattachLayers()
        commit(companion)
    }

    func removeAll() {
        companions.forEach { $0.layer.removeFromSuperlayer() }
        companions.removeAll()
        held = nil
    }

    // MARK: - Clock

    /// One clock for logic and presentation both.
    ///
    /// `NSView.displayLink` rather than CVDisplayLink: it is the supported API
    /// on current macOS, it delivers on the main thread so no hop is needed to
    /// touch AppKit, and it follows the display's actual refresh rate including
    /// ProMotion. The view it hangs off can outlive individual companions but
    /// not a display removal, so `rebuildWindows` re-arms it if its host went
    /// away.
    private func startClock() {
        guard displayLink == nil, let host = windows.values.first?.hostView else { return }
        let link = host.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        clockHost = host
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        tick(now: link.timestamp)
    }

    // MARK: - The tick

    private func tick(now: CFTimeInterval) {
        guard !companions.isEmpty else { return }
        let dt = lastTimestamp > 0 ? CGFloat(now - lastTimestamp) : 1.0 / 60
        lastTimestamp = now
        guard dt > 0 else { return }

        // Phase 1 — sample the world once, so every companion sees the same one.
        let world = worldSurfaces()
        cursor.update(to: NSEvent.mouseLocation, dt: dt)
        let mouseDown = NSEvent.pressedMouseButtons & 1 == 1

        // Phase 2 — advance logic.
        if let companion = held {
            if mouseDown {
                advanceHeld(companion, dt: dt)
            } else {
                release(companion)
            }
        }
        for companion in companions where companion.state != .held {
            advanceFree(companion, dt: dt, world: world.set)
        }

        // Phase 3 — commit presentation.
        for companion in companions { commit(companion) }
        updateClickThrough(mouseDown: mouseDown)
    }

    private func advanceHeld(_ companion: Companion, dt: CGFloat) {
        let target = CGPoint(x: cursor.position.x + companion.grabOffset.dx,
                             y: cursor.position.y + companion.grabOffset.dy)
        if hypot(target.x - companion.anchor.x, target.y - companion.anchor.y) > 3 {
            pressWasDrag = true
        }
        // Position is locked rigidly to the cursor — that directness is what
        // makes grabbing feel immediate. Only the rendered pose lags, via the
        // spring below. Smoothing the position instead produces mush.
        let horizontalTravel = target.x - companion.anchor.x
        companion.anchor = target
        companion.spring.step(target: horizontalTravel * 12, dt: dt)
        companion.landingElapsed = .greatestFiniteMagnitude
    }

    private func advanceFree(_ companion: Companion, dt: CGFloat, world: SurfaceSet) {
        companion.landingElapsed += dt
        companion.spring.step(target: 0, dt: dt)

        switch companion.state {
        case .grounded(let id):
            // Ground can disappear — a display unplugged, a work area resized.
            // Losing it is an ordinary transition here, not the exception
            // Shimeji throws (LostGroundException).
            if let surface = world.surface(with: id), surface.contains(companion.anchor) {
                return
            }
            companion.state = .airborne
            companion.integrator.velocity = .zero
        case .held:
            return
        case .airborne:
            break
        }

        switch companion.integrator.step(from: companion.anchor, dt: dt, in: world) {
        case .airborne(let next):
            companion.anchor = next
        case .contacted(let id, let point):
            companion.anchor = point
            if world.surface(with: id)?.kind == .floor {
                companion.state = .grounded(id)
                companion.landingElapsed = 0
            } else {
                // Walls and ceilings have no cling behaviour until the behavior
                // system lands; slide rather than stick to them.
                companion.state = .airborne
            }
        }
    }

    private func release(_ companion: Companion) {
        companion.state = .airborne
        companion.integrator.velocity = cursor.releaseVelocity()
        held = nil
        if !pressWasDrag { onClick?() }
    }

    // MARK: - World

    private func worldSurfaces() -> (set: SurfaceSet, bounds: CGRect) {
        var all: [Surface] = []
        var bounds = CGRect.null
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            all.append(contentsOf: SurfaceSet.workArea(screen.visibleFrame, displayID: id).surfaces)
            bounds = bounds.union(screen.visibleFrame)
        }
        return (SurfaceSet(all), bounds.isNull ? .zero : bounds)
    }

    // MARK: - Input

    private func handleMouseDown(at point: CGPoint) {
        guard let companion = companions.last(where: { $0.isOpaque(atScreenPoint: point) }) else { return }
        companion.state = .held
        companion.integrator.velocity = .zero
        companion.grabOffset = CGVector(dx: companion.anchor.x - point.x,
                                        dy: companion.anchor.y - point.y)
        companion.spring.reset()
        held = companion
        pressAnchor = point
        pressWasDrag = false
    }

    /// Lifts click-through only while the cursor is on actual artwork.
    ///
    /// Evaluated every frame against the baked alpha mask, versus a 10Hz poll of
    /// a fixed 260x265 rectangle today — which both swallows clicks in the empty
    /// space beside the companion and misses thin parts of it.
    private func updateClickThrough(mouseDown: Bool) {
        let point = cursor.position
        let interactive = held != nil || companions.contains { $0.isOpaque(atScreenPoint: point) }
        for window in windows.values where window.ignoresMouseEvents == interactive {
            window.ignoresMouseEvents = !interactive
        }
    }

    // MARK: - Presentation

    private func commit(_ companion: Companion) {
        guard let window = window(containing: companion.anchor) ?? windows.values.first else { return }
        if companion.layer.superlayer !== window.hostView.layer {
            companion.layer.removeFromSuperlayer()
            window.hostView.layer?.addSublayer(companion.layer)
            companion.layer.contentsScale = window.backingScaleFactor
        }

        let scale = window.backingScaleFactor
        let rect = companion.screenRect()
        // Screen coordinates to window-local, then snapped to the display's
        // physical pixel grid: physics stays continuous so slow drift is smooth,
        // while the sprite lands on whole device pixels so it stays crisp.
        let localOrigin = CGPoint(x: rect.origin.x - window.frame.origin.x,
                                  y: rect.origin.y - window.frame.origin.y)
        let snapped = devicePixelSnapped(CGPoint(x: localOrigin.x + rect.width / 2,
                                                 y: localOrigin.y + rect.height / 2),
                                         scale: scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        companion.layer.contents = companion.currentFrame.image
        companion.layer.bounds = CGRect(origin: .zero, size: rect.size)
        companion.layer.position = snapped
        companion.layer.transform = presentationTransform(for: companion)
        CATransaction.commit()
    }

    /// Sway while held, squash on landing. Both are procedural, so a companion
    /// with only the three generated frames still reads as alive.
    private func presentationTransform(for companion: Companion) -> CATransform3D {
        var transform = CATransform3DIdentity

        if companion.state == .held {
            // The spring output is a horizontal lag in points; as a shear it
            // reads as the body swinging under the hand that holds it.
            let lean = max(-28, min(28, companion.spring.offset))
            transform = CATransform3DConcat(
                CATransform3DMakeAffineTransform(
                    CGAffineTransform(a: 1, b: 0, c: -lean / 240, d: 1, tx: 0, ty: 0)),
                transform)
        }

        let elapsed = companion.landingElapsed
        if elapsed < Self.squashDuration {
            // Decaying cosine: hardest compression on contact, then a couple of
            // diminishing rebounds. Volume is roughly preserved, so it widens as
            // it flattens the way a soft body does.
            let progress = elapsed / Self.squashDuration
            let decay = CGFloat(exp(Double(-5 * progress)))
            let wobble = CGFloat(cos(Double(progress * 3 * .pi))) * decay
            let squashY = 1 - Self.squashDepth * wobble
            let squashX = 1 + Self.squashDepth * wobble * 0.6
            // Scaling about the layer centre would lift the feet off the floor,
            // so shift down by half the height lost and back again.
            let heightLoss = companion.screenRect().height * (1 - squashY) / 2
            transform = CATransform3DConcat(
                CATransform3DMakeScale(squashX, squashY, 1),
                CATransform3DConcat(CATransform3DMakeTranslation(0, -heightLoss, 0), transform))
        }
        return transform
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
