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
    /// Clinging to a wall or hanging from a ceiling: gravity off, anchor
    /// pinned to the surface. Entered on contact while airborne; left the
    /// moment the pack has nothing to do there, so a pack with no attached
    /// behaviours slides off exactly as before the state existed.
    case attached(SurfaceID)
}

/// One companion: where it is, what it is doing, and what it looks like.
final class Companion {
    private(set) var sprite: CompanionSprite
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

    /// Decides what to do when nobody is touching it. Nil until a pack loads,
    /// in which case the companion simply stands where it is.
    var director: CompanionDirector?
    var groundedSeconds: CGFloat = 0
    /// Distance walked, driving the gait bob. Tied to travel rather than to
    /// elapsed time so the bounce cannot drift out of step with the movement —
    /// a time-driven bob on a sliding sprite reads as moonwalking.
    var travelled: CGFloat = 0
    /// Horizontal speed this frame, px/s.
    var walkSpeed: CGFloat = 0
    var airborneSeconds: CGFloat = 0
    var heldSeconds: CGFloat = 0
    var attachedSeconds: CGFloat = 0
    /// State at grab time, so a click — a grab that never moved — can put the
    /// companion back rather than dropping it. Without this a tap on a
    /// grounded companion re-lands it, and landing resets the director, which
    /// wipes the very reaction the tap was meant to trigger.
    var stateBeforeGrab: CompanionMotionState = .airborne

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

    /// Drawn walk cycle, when one exists. Frames are picked by distance
    /// travelled rather than by the behaviour pack or the clock: distance is
    /// what makes footfalls line up with the ground, the same reason the
    /// procedural gait bob keys off `travelled`.
    var walkSprite: CompanionSprite?

    /// Whether the drawn walk frames are what should be on screen right now.
    var walkFramesActive: Bool { walkSprite != nil && walkSpeed > 1 }

    /// The sheet the current frame comes from — walk strip while walking with
    /// real frames, the art sheet otherwise.
    var activeSprite: CompanionSprite { walkFramesActive ? walkSprite! : sprite }

    var currentFrame: CompanionFrame {
        if walkFramesActive, let walkSprite {
            // One drawn cycle covers two strides (left step + right step).
            let cycle = CompanionRuntime.strideLength * 2
            let phase = (travelled / cycle).truncatingRemainder(dividingBy: 1)
            let index = Int(phase * CGFloat(walkSprite.frameCount)) % walkSprite.frameCount
            return walkSprite.frame(index)
        }
        return sprite.frame(frameIndex)
    }

    /// Keeps the anchor fixed across an art swap. Cells carry different
    /// padding, so re-deriving position from the layer rect would make the
    /// familiar hop sideways every time it blinked.
    func replaceSprite(_ next: CompanionSprite, frameIndex index: Int) {
        sprite = next
        frameIndex = max(0, min(index, next.frameCount - 1))
    }

    /// On-screen rect in global (screen) coordinates.
    func screenRect() -> CGRect {
        currentFrame.rect(anchoredAt: anchor, displayHeight: displayHeight, cellSize: activeSprite.cellSize)
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
    /// Pixels of travel per full stride, and how far the body rises within one.
    /// A stride roughly the companion's own height reads naturally.
    static let strideLength: CGFloat = 110
    static let gaitBobHeight: CGFloat = 7
    /// Shear into the direction of travel, at full walking speed.
    static let gaitLean: CGFloat = 0.045

    private var windows: [CGDirectDisplayID: CompanionLayerWindow] = [:]
    private var companions: [Companion] = []
    private var cursor = CursorTracker(position: NSEvent.mouseLocation)
    private var displayLink: CADisplayLink?
    private weak var clockHost: CompanionHostView?
    private var lastTimestamp: CFTimeInterval = 0
    private var held: Companion?
    private var observingScreens = false
    private var behaviorPack: CompanionBehaviorPack?

    /// Mimo's semantic layer, pushed from the focus engine. Behaviour packs
    /// gate on these, which is what lets the companion go quiet during deep
    /// work without a global if — Shimeji has no equivalent input.
    var mood: String = "idle"
    var focusMinutes: Double = 0
    var streakMinutes: Double = 0
    var level: Double = 1

    /// Raised on a click that was a click, not a drag.
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    private var pressAnchor: CGPoint = .zero
    private var pressWasDrag = false

    var isEmpty: Bool { companions.isEmpty }

    // MARK: - Lifecycle

    func start() {
        rebuildWindows()
        // Switching familiars re-enters this; without the guard every switch
        // would stack another screen-parameters observer.
        if !observingScreens {
            NotificationCenter.default.addObserver(
                self, selector: #selector(screensChanged),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            observingScreens = true
        }
        startClock()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        clockHost = nil
        NotificationCenter.default.removeObserver(self)
        observingScreens = false
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
        companion.director = behaviorPack.map { CompanionDirector(pack: $0) }
        companion.walkSprite = walkSprite
        companions.append(companion)
        reattachLayers()
        commit(companion)
    }

    /// Swaps the artwork every companion draws. The webview owns the mood and
    /// evolution state, so it decides which sheet and frame; this just applies it.
    func setArt(sprite: CompanionSprite, frameIndex: Int) {
        for companion in companions {
            companion.replaceSprite(sprite, frameIndex: frameIndex)
        }
    }

    /// Installs (or clears) the drawn walk cycle on every companion, present
    /// and future. Kept separate from `setArt`: expression swaps replace the
    /// standing art many times a minute and must not disturb the walk strip.
    func setWalkSprite(_ sprite: CompanionSprite?) {
        walkSprite = sprite
        for companion in companions { companion.walkSprite = sprite }
    }
    private var walkSprite: CompanionSprite?

    func removeAll() {
        companions.forEach { $0.layer.removeFromSuperlayer() }
        companions.removeAll()
        held = nil
        walkSprite = nil
        releaseClickThrough()
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
        guard !companions.isEmpty else {
            // Nothing to draw — hand every click back to the desktop. Bailing
            // out without this leaves a full-screen transparent window latched
            // interactive, swallowing every click on the machine.
            releaseClickThrough()
            lastTimestamp = 0
            return
        }
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
                companion.heldSeconds += dt
                advanceHeld(companion, dt: dt)
            } else {
                release(companion, world: world.set)
            }
        }
        for companion in companions where companion.state != .held {
            advanceFree(companion, dt: dt, world: world.set)
            recoverIfLost(companion)
        }

        reportBehaviorIfChanged()

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
            guard let surface = world.surface(with: id), surface.contains(companion.anchor) else {
                companion.state = .airborne
                companion.integrator.velocity = .zero
                break
            }
            companion.groundedSeconds += dt
            walk(companion, on: surface, dt: dt, world: world)
            return
        case .attached(let id):
            guard let surface = world.surface(with: id), surface.contains(companion.anchor) else {
                companion.state = .airborne
                companion.integrator.velocity = .zero
                break
            }
            companion.attachedSeconds += dt
            cling(companion, to: surface, dt: dt, world: world)
            return
        case .held:
            return
        case .airborne:
            companion.airborneSeconds += dt
        }

        switch companion.integrator.step(from: companion.anchor, dt: dt, in: world) {
        case .airborne(let next):
            companion.anchor = next
        case .contacted(let id, let point):
            companion.anchor = point
            if world.surface(with: id)?.kind == .floor {
                companion.state = .grounded(id)
                companion.landingElapsed = 0
                companion.groundedSeconds = 0
                companion.airborneSeconds = 0
                companion.director?.reset()
            } else {
                // Cling tentatively and let the urn decide: if the pack has an
                // attached behaviour whose condition passes, it runs; if not,
                // `cling` detaches on the next frame and the companion falls,
                // which is the old slide with one extra frame of contact.
                companion.state = .attached(id)
                companion.attachedSeconds = 0
                companion.airborneSeconds = 0
                companion.director?.reset()
            }
        }
    }

    /// Runs the behaviour pack for a grounded companion and walks it.
    ///
    /// Movement is applied along the surface: y stays pinned to the floor, so a
    /// walk cannot drift off it, and reaching either end of the span ends the
    /// action rather than stepping into space.
    private func walk(_ companion: Companion, on surface: Surface,
                      dt: CGFloat, world: SurfaceSet) {
        guard let director = companion.director else { return }
        let intent = director.update(dt: Double(dt), snapshot: snapshot(for: companion, world: world))
        // Only an action sheet's frames mean poses. On a stage or expression
        // sheet the same index means something else entirely, and applying a
        // pack's pose index to a stage sheet is what made a familiar revert to
        // its youngest form the moment it landed.
        if companion.sprite.framesAreBehaviourDriven {
            companion.frameIndex = min(max(intent.frame, 0), companion.sprite.frameCount - 1)
        }
        companion.facingRight = intent.facingRight

        guard intent.embedded == nil, intent.velocity.dx != 0 else {
            companion.walkSpeed = 0
            return
        }

        let next = companion.anchor.x + intent.velocity.dx * dt
        let margin: CGFloat = 4
        let lower = surface.span.lowerBound + margin
        let upper = surface.span.upperBound - margin
        guard lower <= upper else { return }

        if next < lower || next > upper {
            // Walked into the edge of the world. Stop here and let the pack
            // choose again rather than sliding along the boundary.
            companion.anchor.x = min(max(next, lower), upper)
            director.reset()
            return
        }
        companion.anchor.x = next
        companion.anchor.y = surface.position
        companion.travelled += abs(intent.velocity.dx) * dt
        companion.walkSpeed = abs(intent.velocity.dx)
    }

    /// Runs the behaviour pack for an attached companion.
    ///
    /// Same shape as `walk`, rotated: the anchor is pinned to the surface on
    /// its constant axis and pose velocity moves it along the span — dy climbs
    /// a wall, dx traverses a ceiling. If the pack selects nothing (no attached
    /// behaviours, or all of them gated off), the companion lets go and falls;
    /// hanging forever with nothing to do would turn a missing behaviour into
    /// a companion glued to the wall.
    private func cling(_ companion: Companion, to surface: Surface,
                       dt: CGFloat, world: SurfaceSet) {
        guard let director = companion.director else {
            companion.state = .airborne
            return
        }
        let intent = director.update(dt: Double(dt), snapshot: snapshot(for: companion, world: world))
        if director.currentBehaviorName == nil {
            companion.state = .airborne
            companion.integrator.velocity = .zero
            director.reset()
            return
        }
        if companion.sprite.framesAreBehaviourDriven {
            companion.frameIndex = min(max(intent.frame, 0), companion.sprite.frameCount - 1)
        }
        companion.walkSpeed = 0

        let along = surface.isVertical ? intent.velocity.dy : intent.velocity.dx
        if surface.isVertical {
            companion.anchor.x = surface.position
        } else {
            companion.anchor.y = surface.position
        }
        guard intent.embedded == nil, along != 0 else { return }

        let margin: CGFloat = 4
        let lower = surface.span.lowerBound + margin
        let upper = surface.span.upperBound - margin
        guard lower <= upper else { return }

        let current = surface.isVertical ? companion.anchor.y : companion.anchor.x
        let next = current + along * dt
        let clamped = min(max(next, lower), upper)
        if surface.isVertical {
            companion.anchor.y = clamped
        } else {
            companion.anchor.x = clamped
        }
        if next != clamped {
            // Climbed to the end of the surface. Stop and let the pack choose
            // again rather than crawling into space.
            director.reset()
        }
    }

    /// The world as a behaviour pack is allowed to see it.
    private func snapshot(for companion: Companion, world: SurfaceSet) -> CompanionSnapshot {
        var snapshot = CompanionSnapshot()
        switch companion.state {
        case .grounded:
            snapshot.state = "grounded"
            snapshot.surface = "floor"
        case .airborne:
            snapshot.state = "airborne"
        case .held:
            snapshot.state = "held"
        case .attached(let id):
            snapshot.state = "attached"
            switch world.surface(with: id)?.kind {
            case .wall: snapshot.surface = "wall"
            case .ceiling: snapshot.surface = "ceiling"
            case .floor: snapshot.surface = "floor"
            case nil: snapshot.surface = "none"
            }
        }
        snapshot.anchorX = Double(companion.anchor.x)
        snapshot.anchorY = Double(companion.anchor.y)
        snapshot.lookRight = companion.facingRight
        snapshot.footX = Double(companion.spring.offset)
        snapshot.heldSeconds = Double(companion.heldSeconds)
        snapshot.groundedSeconds = Double(companion.groundedSeconds)
        snapshot.airborneSeconds = Double(companion.airborneSeconds)
        snapshot.attachedSeconds = Double(companion.attachedSeconds)
        snapshot.cursorX = Double(cursor.position.x)
        snapshot.cursorY = Double(cursor.position.y)
        snapshot.cursorDX = Double(cursor.velocity.dx)
        snapshot.cursorDY = Double(cursor.velocity.dy)

        let screen = NSScreen.screens.first { $0.frame.contains(companion.anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        snapshot.displayWidth = Double(visible.width)
        snapshot.displayHeight = Double(visible.height)
        snapshot.workAreaLeft = Double(visible.minX)
        snapshot.workAreaRight = Double(visible.maxX)
        snapshot.workAreaTop = Double(visible.maxY)
        snapshot.workAreaBottom = Double(visible.minY)

        snapshot.companionCount = Double(companions.count)
        snapshot.mood = mood
        snapshot.focusMinutes = focusMinutes
        snapshot.streakMinutes = streakMinutes
        snapshot.level = level
        snapshot.isIdle = mood == "idle"
        return snapshot
    }

    /// Installs the pack every companion runs. Existing companions adopt it
    /// immediately so switching packs does not need a respawn.
    func setBehaviorPack(_ pack: CompanionBehaviorPack?) {
        behaviorPack = pack
        for companion in companions {
            companion.director = pack.map { CompanionDirector(pack: $0) }
        }
    }

    /// Reports what the companion is doing, when it changes.
    private func reportBehaviorIfChanged() {
        guard let companion = companions.first else { return }
        let state: String
        switch companion.state {
        case .grounded: state = "grounded"
        case .airborne: state = "airborne"
        case .held: state = "held"
        case .attached: state = "attached"
        }
        let behavior = companion.director == nil
            ? "no behavior pack loaded"
            : (companion.director?.currentBehaviorName ?? "nothing selectable")
        let line = "\(behavior)  [state=\(state) mood=\(mood) focus=\(Int(focusMinutes))m]"
        guard line != lastReportedBehavior else { return }
        lastReportedBehavior = line
        onBehaviorChanged?(line)
    }

    /// Puts a companion back if it has left the world.
    ///
    /// Runs every frame rather than only on a display change, because the way
    /// a companion is actually lost is being thrown into the strip behind the
    /// Dock — below the work-area floor, which from underneath can never be
    /// reached again. Held companions are exempt: the cursor is allowed
    /// anywhere, and recovery applies once it is let go.
    private func recoverIfLost(_ companion: Companion) {
        let workAreas = NSScreen.screens.map(\.visibleFrame)
        guard let recovered = CompanionRecovery.recoveredAnchor(for: companion.anchor,
                                                                workAreas: workAreas) else { return }
        companion.anchor = recovered
        companion.integrator.velocity = .zero
        companion.state = .airborne
        companion.landingElapsed = .greatestFiniteMagnitude
        companion.director?.reset()
        onRecovered?("companion left the screen; returned it to the nearest work area")
    }

    /// Raised when a companion had to be rescued, so it is never silent.
    var onRecovered: ((String) -> Void)?

    /// Raised when the running behaviour changes, so what the companion is
    /// doing and why is answerable from outside.
    ///
    /// Without this, "it isn't moving" has several indistinguishable causes:
    /// no pack loaded, a pack that loaded but gates everything off, or the
    /// companion correctly staying quiet because the user is in deep work.
    /// Guessing between them cost a debugging round.
    var onBehaviorChanged: ((String) -> Void)?
    private var lastReportedBehavior: String?

    private func release(_ companion: Companion, world: SurfaceSet) {
        held = nil
        guard !pressWasDrag else {
            companion.state = .airborne
            companion.integrator.velocity = cursor.releaseVelocity()
            return
        }
        // A grab that never moved is a click: put the companion back rather
        // than dropping it — the drop would land, and landing resets the
        // director, wiping the very reaction being triggered — then let the
        // pack answer. Only when it has no answer (no reaction declared, or
        // its behaviour is gated off right now) does the click fall through
        // to the app's own handler.
        if !restoreAfterClick(companion, world: world) {
            companion.state = .airborne
            companion.integrator.velocity = .zero
        }
        let triggered = companion.director?.trigger(
            reactionTo: "click",
            snapshot: snapshot(for: companion, world: world)) ?? false
        if !triggered { onClick?() }
    }

    /// Puts a clicked companion back into its pre-grab state, if that state
    /// still exists. The cursor may wander a couple of points during a click
    /// without counting as a drag, so the anchor is snapped back onto the
    /// surface rather than tested against the 1px resting tolerance.
    private func restoreAfterClick(_ companion: Companion, world: SurfaceSet) -> Bool {
        let slack: CGFloat = 8
        switch companion.stateBeforeGrab {
        case .grounded(let id):
            guard let surface = world.surface(with: id), surface.kind == .floor,
                  surface.span.contains(companion.anchor.x),
                  abs(companion.anchor.y - surface.position) <= slack else { return false }
            companion.anchor.y = surface.position
            companion.state = .grounded(id)
            return true
        case .attached(let id):
            guard let surface = world.surface(with: id) else { return false }
            if surface.isVertical {
                guard surface.span.contains(companion.anchor.y),
                      abs(companion.anchor.x - surface.position) <= slack else { return false }
                companion.anchor.x = surface.position
            } else {
                guard surface.span.contains(companion.anchor.x),
                      abs(companion.anchor.y - surface.position) <= slack else { return false }
                companion.anchor.y = surface.position
            }
            companion.state = .attached(id)
            return true
        case .airborne, .held:
            return false
        }
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
        companion.stateBeforeGrab = companion.state
        companion.state = .held
        companion.integrator.velocity = .zero
        companion.grabOffset = CGVector(dx: companion.anchor.x - point.x,
                                        dy: companion.anchor.y - point.y)
        companion.spring.reset()
        companion.heldSeconds = 0
        // The pack does not get to argue with the cursor.
        companion.director?.reset()
        held = companion
        pressAnchor = point
        pressWasDrag = false
    }

    /// Lifts click-through only while the cursor is on actual artwork.
    ///
    /// Evaluated every frame against the baked alpha mask, versus a 10Hz poll of
    /// a fixed 260x265 rectangle today — which both swallows clicks in the empty
    /// space beside the companion and misses thin parts of it.
    /// Forces every window back to click-through.
    private func releaseClickThrough() {
        for window in windows.values where !window.ignoresMouseEvents {
            window.ignoresMouseEvents = true
        }
    }

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

        // Sprites are authored facing one way; the other is a mirror. This is
        // also why the anchor is stored in cell space — reflecting it is
        // `width - anchorX`, so an asymmetric figure still stands on its feet.
        if companion.facingRight {
            transform = CATransform3DConcat(CATransform3DMakeScale(-1, 1, 1), transform)
        }

        if companion.state == .held {
            // The spring output is a horizontal lag in points; as a shear it
            // reads as the body swinging under the hand that holds it.
            let lean = max(-28, min(28, companion.spring.offset))
            transform = CATransform3DConcat(
                CATransform3DMakeAffineTransform(
                    CGAffineTransform(a: 1, b: 0, c: -lean / 240, d: 1, tx: 0, ty: 0)),
                transform)
        }

        // A walk with no authored frames is just a sprite sliding sideways.
        // Until an action strip is installed, a gait bob and a slight forward
        // lean carry it: the body rises and falls twice per stride and tips
        // into the direction of travel, which is most of what reads as
        // walking. With real frames on screen both come off — the drawn cycle
        // already contains the body's rise, fall, and lean, and stacking the
        // procedural versions on top reads as bouncing on a trampoline.
        //
        // Phase comes from distance travelled, not from the clock, so the
        // bounce stays locked to the movement at any speed.
        if companion.walkSpeed > 1, !companion.walkFramesActive {
            let phase = companion.travelled / Self.strideLength * 2 * .pi
            let bob = -abs(sin(phase)) * Self.gaitBobHeight
            let lean = Self.gaitLean * min(1, companion.walkSpeed / 120)
            transform = CATransform3DConcat(
                CATransform3DMakeAffineTransform(
                    CGAffineTransform(a: 1, b: 0, c: companion.facingRight ? lean : -lean,
                                      d: 1, tx: 0, ty: 0)),
                transform)
            transform = CATransform3DConcat(CATransform3DMakeTranslation(0, bob, 0), transform)
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
