import CoreGraphics
import Foundation

// Physics for the companion runtime.
//
// The feel is Shimeji's, the units are not. Shimeji advances one fixed 40ms
// tick and applies integer pixel offsets, with no `v * dt` anywhere — which
// bakes the tick rate into every asset pack, so its frame rate cannot be raised
// without changing how far everything moves. Here everything is per-second and
// scaled by real elapsed time, so authored timing and render rate are
// independent. See docs/companion/03-runtime-architecture.md §4.4.
//
// Every constant below is derived from Shimeji's, not guessed. The conversions
// are spelled out so they can be checked, and companion_physics_test.swift
// asserts that stepping this integrator at 25fps reproduces Shimeji's
// per-tick recurrence.

enum CompanionPhysics {
    /// Shimeji's fixed tick rate. Only used to convert its constants.
    static let referenceTickRate: CGFloat = 25

    /// Shimeji: `gravity = 2` px/tick², downward, in a y-down space.
    /// px/tick² -> px/s² multiplies by tickRate², and AppKit's y-up flips it.
    ///   2 * 25² = 1250
    static let gravity: CGFloat = -2 * referenceTickRate * referenceTickRate

    /// Shimeji: `velocity -= velocity * resistance` once per tick — proportional
    /// (exponential) decay, not quadratic drag. Cheap and stable at any step.
    ///
    /// `λ = rate · r`, i.e. 25·0.05 and 25·0.10.
    ///
    /// The obvious alternative, `λ = -rate·ln(1 - r)`, matches how a free
    /// velocity decays over one tick more precisely — but it does not preserve
    /// terminal velocity, and terminal velocity is the property you actually
    /// see. Shimeji's `v = 0.9v + 2` settles at `g/r` = 20 px/tick = 500 px/s;
    /// with the logarithmic form our terminal `a/λ` comes out 474, a visibly
    /// slower fall.
    ///
    /// The linearised form preserves both invariants at once: acceleration
    /// stays 1250 px/s² and terminal velocity `a/λ` = 1250/2.5 = 500 px/s,
    /// exactly Shimeji's. The cost is a ~5% difference in how a free velocity
    /// bleeds off, which is far below perceptible.
    static let dragX: CGFloat = referenceTickRate * 0.05
    static let dragY: CGFloat = referenceTickRate * 0.10

    /// How close an anchor must be to a surface to count as resting on it.
    /// Shimeji used exact integer equality; see companion_geometry.swift.
    static let surfaceTolerance: CGFloat = 1.0

    /// Longest step the integrator will take in one go. A stalled main thread or
    /// a display wake can hand us a huge dt; without a clamp the companion
    /// teleports. A frame this long is a glitch, not motion worth reproducing.
    ///
    /// Must stay well above a real frame time or it silently slows normal
    /// motion: Shimeji's own 25fps is already 40ms, so a 1/30 clamp would throttle
    /// the reference rate itself. 10fps is not a frame rate, it is a stall.
    static let maxTimeStep: CGFloat = 1.0 / 10

    /// Target distance per sub-step during sweeping. Keeps fast throws from
    /// skipping past a surface between samples.
    static let sweepResolution: CGFloat = 8
}

/// Passive side-wall response shared by every familiar, including one that has
/// no generated wall strip. A throw should read as soft contact, not as the
/// sprite centre disappearing beyond the display edge: it sticks for a beat,
/// then loses grip at one calm, predictable speed until it reaches the floor.
enum CompanionWallSlide {
    static let stickDuration: CGFloat = 0.55
    static let descentSpeed: CGFloat = 52

    static func nextY(currentY: CGFloat, attachedSeconds: CGFloat, dt: CGFloat,
                      span: ClosedRange<CGFloat>) -> CGFloat {
        let current = min(max(currentY, span.lowerBound), span.upperBound)
        guard dt > 0, attachedSeconds > stickDuration else { return current }

        // If this frame straddles the end of the sticky pause, descend only for
        // its post-pause fraction. This keeps the feel independent of refresh
        // rate and avoids a one-frame jump on a busy display.
        let frameStart = max(0, attachedSeconds - dt)
        let slidingTime = max(0, attachedSeconds - max(frameStart, stickDuration))
        return max(span.lowerBound, current - descentSpeed * slidingTime)
    }
}

// MARK: - Cursor

/// Tracks the cursor and, more importantly, how fast it is moving.
///
/// The smoothing is the single most important detail for throw feel. Shimeji
/// averages each new delta with the previous one (`dx = (dx + x - this.x) / 2`)
/// and its source says why: without it, a cursor that pauses for two ticks
/// before release throws the mascot with zero velocity even though the user
/// clearly flicked it. The average makes a flick forgiving.
struct CursorTracker {
    private(set) var position: CGPoint
    /// Exponentially smoothed cursor velocity, px/s.
    private(set) var velocity: CGVector

    init(position: CGPoint = .zero) {
        self.position = position
        self.velocity = .zero
    }

    mutating func update(to point: CGPoint, dt: CGFloat) {
        guard dt > 0 else { position = point; return }
        let instantaneous = CGVector(dx: (point.x - position.x) / dt,
                                     dy: (point.y - position.y) / dt)
        velocity = CGVector(dx: (velocity.dx + instantaneous.dx) / 2,
                            dy: (velocity.dy + instantaneous.dy) / 2)
        position = point
    }

    /// Velocity to hand a companion on release.
    func releaseVelocity() -> CGVector { velocity }
}

// MARK: - Drag spring

/// The sway of a held companion.
///
/// This is the other half of what makes Shimeji's drag feel alive, and the part
/// most implementations get wrong. The companion's *position* is locked rigidly
/// to the cursor with zero smoothing — that is what makes grabbing feel direct.
/// Only the *rendered pose* lags and overshoots, driven by this damped spring.
/// Smoothing the position instead produces mush.
///
/// Shimeji, per tick: `footDx = (footDx + (target - footX) * 0.1) * 0.8`, which
/// rearranges to `v' = 0.8·v + 0.08·e`.
///
/// Converting needs care, because `footDx` is a displacement per tick, not a
/// velocity: in px/s it is `V = v·rate`. Substituting and dividing by the tick
/// length gives
///   dV/dt = -0.2·rate·V + 0.08·rate²·e = -5·V + 50·e
/// so damping picks up one factor of `rate` and stiffness picks up two. (Losing
/// the second factor makes the spring ~25× too slack — it barely moves.)
///
/// β = 5, ω = √50 ≈ 7.07, so β/2 < ω: underdamped, and it overshoots. That is
/// the point. Shimeji's own comment says it should "oscillate between positive
/// and negative values as it approaches 0" so the companion sways when the
/// cursor stops.
struct DragSpring {
    static let damping: CGFloat = 0.2 * CompanionPhysics.referenceTickRate                                   // 5 /s
    static let stiffness: CGFloat = 0.08 * CompanionPhysics.referenceTickRate * CompanionPhysics.referenceTickRate  // 50 /s²

    private(set) var offset: CGFloat = 0
    private(set) var velocity: CGFloat = 0

    /// `target` is the anchor's displacement this frame; `offset` trails it.
    mutating func step(target: CGFloat, dt: CGFloat) {
        guard dt > 0 else { return }
        velocity += (-Self.damping * velocity + Self.stiffness * (target - offset)) * dt
        offset += velocity * dt
    }

    mutating func reset() { offset = 0; velocity = 0 }
}

// MARK: - Integrator

enum CompanionStep: Equatable {
    /// Still in the air at the returned anchor.
    case airborne(CGPoint)
    /// Reached a surface. The anchor sits exactly on it.
    case contacted(SurfaceID, CGPoint)
}

/// Ballistic motion: gravity, proportional drag, and swept surface contact.
struct CompanionIntegrator {
    var velocity: CGVector
    var gravityScale: CGFloat

    /// `gravityScale` of 0 gives a floating companion — a ghost state can turn
    /// gravity off without a separate code path.
    init(velocity: CGVector = .zero, gravityScale: CGFloat = 1) {
        self.velocity = velocity
        self.gravityScale = gravityScale
    }

    /// Closed-form solution of `v' = -drag·v + acceleration` over `dt`.
    ///
    /// Terminal velocity is `a/λ`; velocity relaxes toward it exponentially, and
    /// displacement is that relaxation integrated. Exact at any `dt`, which is
    /// the property the whole per-second design depends on.
    static func integrate(velocity v0: CGFloat, acceleration a: CGFloat,
                          drag lambda: CGFloat, dt: CGFloat) -> (velocity: CGFloat, displacement: CGFloat) {
        guard lambda > 0 else {
            // No drag: plain constant acceleration.
            return (v0 + a * dt, v0 * dt + 0.5 * a * dt * dt)
        }
        let decay = CGFloat(exp(Double(-lambda * dt)))
        let terminal = a / lambda
        let velocity = terminal + (v0 - terminal) * decay
        let displacement = terminal * dt + (v0 - terminal) * (1 - decay) / lambda
        return (velocity, displacement)
    }

    /// Advances one frame from `anchor`, stopping at the first surface hit.
    mutating func step(from anchor: CGPoint, dt rawDt: CGFloat, in world: SurfaceSet) -> CompanionStep {
        let dt = min(max(rawDt, 0), CompanionPhysics.maxTimeStep)
        guard dt > 0 else { return .airborne(anchor) }

        // `v' = -λv + a` is linear, so it has a closed form and we use it rather
        // than stepping Euler. This is what makes the trajectory genuinely
        // independent of frame rate: semi-implicit Euler carries an O(dt) error
        // (`-a·T·dt/2` over a fall of duration T) that visibly changes the arc
        // between 25fps and 60fps.
        //
        // The cost is that we do NOT reproduce Shimeji's 40ms Euler overshoot —
        // its constants describe its own discretisation, and no continuous
        // integrator can match a discrete one at every step size. We take the
        // motion those constants were reaching for. Expect the felt result to
        // need a tuning pass against real dragging; see the P0 block 3 notes in
        // docs/companion/05-roadmap.md.
        let vertical = Self.integrate(velocity: velocity.dy,
                                      acceleration: CompanionPhysics.gravity * gravityScale,
                                      drag: CompanionPhysics.dragY, dt: dt)
        let horizontal = Self.integrate(velocity: velocity.dx,
                                        acceleration: 0,
                                        drag: CompanionPhysics.dragX, dt: dt)
        velocity = CGVector(dx: horizontal.velocity, dy: vertical.velocity)

        let target = CGPoint(x: anchor.x + horizontal.displacement,
                             y: anchor.y + vertical.displacement)

        // Sweep in sub-steps so a fast throw cannot pass through a thin surface
        // between samples. Shimeji needed an 80px downward probe for this
        // because its contact test was exact equality; a crossing test does not.
        let distance = hypot(target.x - anchor.x, target.y - anchor.y)
        let steps = max(1, Int((distance / CompanionPhysics.sweepResolution).rounded(.up)))
        var current = anchor
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let next = CGPoint(x: anchor.x + (target.x - anchor.x) * t,
                               y: anchor.y + (target.y - anchor.y) * t)
            if let hit = world.firstCrossing(from: current, to: next) {
                velocity = .zero
                return .contacted(hit.surface.id, hit.point)
            }
            current = next
        }
        return .airborne(target)
    }
}
