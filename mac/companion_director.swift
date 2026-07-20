import CoreGraphics
import Foundation

// Runs one companion's behaviour: pick a behaviour, run its action to
// completion, pick again.
//
// There is no separate state machine driving transitions. As in Shimeji, an
// action's own termination predicate *is* the transition — when it reports it
// has no next step, the selector runs. What differs is that illegality is
// declared rather than discovered: an action names the state it requires, so a
// companion that loses its footing changes state through an ordinary path
// instead of Shimeji's LostGroundException thrown out of a tick.
//
// Kept free of AppKit so the whole loop is testable. The runtime hands it a
// snapshot each frame and applies whatever it asks for.

/// What the director wants the runtime to do this frame.
struct CompanionIntent: Equatable {
    /// Horizontal velocity in px/second from the authored pose.
    var velocity: CGVector = .zero
    /// Frame index to draw.
    var frame: Int = 0
    /// Whether the companion should face right.
    var facingRight: Bool = false
    /// Native behaviour to hand off to, if the action is embedded.
    var embedded: String?
}

/// Everything the director is allowed to see about the world.
struct CompanionSnapshot: CompanionVariableSource {
    var state: String = "grounded"
    /// Kind of surface currently under (or behind) the companion:
    /// "floor" | "wall" | "ceiling" | "none".
    var surface: String = "none"
    var anchorX: Double = 0
    var anchorY: Double = 0
    var lookRight: Bool = false
    var footX: Double = 0
    var heldSeconds: Double = 0
    var groundedSeconds: Double = 0
    var airborneSeconds: Double = 0
    var attachedSeconds: Double = 0
    var cursorX: Double = 0
    var cursorY: Double = 0
    var cursorDX: Double = 0
    var cursorDY: Double = 0
    var displayWidth: Double = 0
    var displayHeight: Double = 0
    var workAreaLeft: Double = 0
    var workAreaRight: Double = 0
    var workAreaTop: Double = 0
    var workAreaBottom: Double = 0
    var companionCount: Double = 1
    var mood: String = "idle"
    var focusMinutes: Double = 0
    var streakMinutes: Double = 0
    var level: Double = 1
    var isIdle: Bool = true
    var paused: Bool = false

    func value(for name: String) -> CompanionValue? {
        switch name {
        case "self.state": return .text(state)
        case "self.surface": return .text(surface)
        case "self.anchor.x": return .number(anchorX)
        case "self.anchor.y": return .number(anchorY)
        case "self.lookRight": return .boolean(lookRight)
        case "self.footX": return .number(footX)
        case "self.heldSeconds": return .number(heldSeconds)
        case "self.groundedSeconds": return .number(groundedSeconds)
        case "self.airborneSeconds": return .number(airborneSeconds)
        case "self.attachedSeconds": return .number(attachedSeconds)
        case "world.cursor.x": return .number(cursorX)
        case "world.cursor.y": return .number(cursorY)
        case "world.cursor.dx": return .number(cursorDX)
        case "world.cursor.dy": return .number(cursorDY)
        case "world.display.width": return .number(displayWidth)
        case "world.display.height": return .number(displayHeight)
        case "world.display.workArea.left": return .number(workAreaLeft)
        case "world.display.workArea.right": return .number(workAreaRight)
        case "world.display.workArea.top": return .number(workAreaTop)
        case "world.display.workArea.bottom": return .number(workAreaBottom)
        case "world.companionCount": return .number(companionCount)
        case "mimo.mood": return .text(mood)
        case "mimo.focusMinutes": return .number(focusMinutes)
        case "mimo.streakMinutes": return .number(streakMinutes)
        case "mimo.level": return .number(level)
        case "mimo.isIdle": return .boolean(isIdle)
        case "mimo.paused": return .boolean(paused)
        default: return nil
        }
    }
}

final class CompanionDirector {
    private let pack: CompanionBehaviorPack
    private let selector: CompanionBehaviorSelector
    private let random: () -> Double

    private(set) var currentBehavior: CompanionBehavior?
    private(set) var currentAction: CompanionAction?
    /// Seconds the current action has been running.
    private(set) var elapsed: Double = 0

    /// `${...}` values resolved when the action started. Re-resolving them per
    /// frame would re-roll a randomised duration forever, so it never elapses.
    private var frozenDuration: Double?
    private var frozenTargetX: Double?

    init(pack: CompanionBehaviorPack, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.pack = pack
        self.selector = CompanionBehaviorSelector(pack: pack)
        self.random = random
    }

    var currentBehaviorName: String? { currentBehavior?.name }

    /// Advances by `dt` and returns what to do this frame.
    func update(dt: Double, snapshot: CompanionSnapshot) -> CompanionIntent {
        // Being grabbed or thrown outranks whatever the pack was doing. This is
        // Shimeji's one cold interruption rule: the companion never ignores
        // your hand.
        if snapshot.state == "held" || snapshot.state == "airborne" {
            if currentAction?.requires.isSatisfied(by: snapshot.state) != true {
                clear()
            }
        }

        if currentAction == nil || isFinished(snapshot: snapshot) {
            advanceToNextBehavior(snapshot: snapshot)
        }
        guard let action = currentAction else { return CompanionIntent() }

        elapsed += dt

        if action.kind == .embedded {
            return CompanionIntent(velocity: .zero, frame: 0,
                                   facingRight: snapshot.lookRight,
                                   embedded: action.implementation)
        }

        guard let animation = action.animation(for: snapshot),
              let pose = animation.pose(at: elapsed) else {
            return CompanionIntent(frame: 0, facingRight: snapshot.lookRight)
        }

        var velocity = pose.velocity
        var facingRight = snapshot.lookRight

        if action.kind == .move, let target = frozenTargetX {
            // Walk toward the target rather than in the pose's authored
            // direction, and face the way we are going. The pose supplies
            // speed; the action supplies intent.
            let delta = target - snapshot.anchorX
            let speed = abs(velocity.dx)
            velocity.dx = delta >= 0 ? speed : -speed
            facingRight = delta >= 0
        } else if velocity.dx != 0 {
            facingRight = velocity.dx > 0
        }

        return CompanionIntent(velocity: velocity, frame: pose.frame,
                               facingRight: facingRight, embedded: nil)
    }

    /// Forces reselection, e.g. after the pack or the familiar changes.
    func reset() {
        clear()
        currentBehavior = nil
    }

    /// Interrupts whatever is running with the pack's reaction to `event`
    /// (e.g. a click), if the pack declares one that is legal right now.
    /// Returns whether anything was triggered, so the caller can fall back.
    ///
    /// The reaction is an ordinary behaviour: its `next` chain decides what
    /// happens after, which is where a personality shows — a playful pack
    /// chains back to what it was doing, a placid one does not.
    func trigger(reactionTo event: String, snapshot: CompanionSnapshot) -> Bool {
        guard let name = pack.reactions[event],
              let behavior = pack.behavior(named: name),
              let action = pack.action(named: behavior.actionName),
              action.requires.isSatisfied(by: snapshot.state),
              behavior.isEffective(for: snapshot) else { return false }
        clear()
        currentBehavior = behavior
        currentAction = action
        frozenDuration = action.duration?.evaluateDouble(snapshot, random: random)
        frozenTargetX = action.targetX?.evaluateDouble(snapshot, random: random)
        return true
    }

    // MARK: - Internals

    private func clear() {
        currentAction = nil
        elapsed = 0
        frozenDuration = nil
        frozenTargetX = nil
    }

    private func isFinished(snapshot: CompanionSnapshot) -> Bool {
        guard let action = currentAction else { return true }

        // An action whose required state no longer holds ends immediately.
        // Shimeji signals this by throwing out of the tick; declaring the
        // requirement makes it an ordinary check.
        if !action.requires.isSatisfied(by: snapshot.state) { return true }

        if let duration = frozenDuration, elapsed >= duration { return true }

        if action.kind == .move, let target = frozenTargetX {
            // Arrival tolerance is one frame of travel, so a companion cannot
            // oscillate around a target it can never land on exactly.
            if abs(target - snapshot.anchorX) <= 4 { return true }
        }

        if action.kind == .animate, let animation = action.animation(for: snapshot) {
            if elapsed >= animation.totalDuration { return true }
        }
        return false
    }

    private func advanceToNextBehavior(snapshot: CompanionSnapshot) {
        clear()

        var candidate = selector.selectNext(after: currentBehavior, source: snapshot,
                                            random: random)

        // A chain can lead somewhere that is legal in the pack but illegal
        // right now — the previous action changed the state on its way out.
        // Retry from a clean slate before giving up.
        if let picked = candidate,
           let action = pack.action(named: picked.actionName),
           !action.requires.isSatisfied(by: snapshot.state) {
            candidate = selector.selectNext(after: nil, source: snapshot, random: random)
        }

        guard let behavior = candidate,
              let action = pack.action(named: behavior.actionName),
              action.requires.isSatisfied(by: snapshot.state) else {
            // Nothing is drawable. Leave the companion idle rather than
            // teleporting it above the screen the way Shimeji does; the runtime
            // already recovers a companion that is genuinely out of bounds, and
            // silently raining from the sky is a terrible diagnostic.
            currentBehavior = nil
            return
        }

        currentBehavior = behavior
        currentAction = action
        elapsed = 0
        frozenDuration = action.duration?.evaluateDouble(snapshot, random: random)
        frozenTargetX = action.targetX?.evaluateDouble(snapshot, random: random)
    }
}
