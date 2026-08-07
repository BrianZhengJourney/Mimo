// sources: companion_geometry.swift companion_physics.swift
import CoreGraphics
import Foundation

@main
struct CompanionPhysicsTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func expectClose(_ actual: CGFloat, _ expected: CGFloat,
                            _ tolerance: CGFloat, _ label: String) {
        precondition(abs(actual - expected) <= tolerance,
                     "\(label): expected \(expected) ± \(tolerance), got \(actual)")
    }

    // MARK: - Surfaces

    static func testWorkAreaSurfaces() {
        let rect = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let world = SurfaceSet.workArea(rect, displayID: 1)
        expect(world.surfaces.count == 4, "work area should produce four surfaces")

        let floor = world.surface(with: .workAreaBottom(displayID: 1))!
        expect(floor.kind == .floor, "work area bottom is a floor")
        expect(floor.contains(CGPoint(x: 800, y: 0)), "anchor on the floor rests on it")
        expect(floor.contains(CGPoint(x: 800, y: 0.5)), "within tolerance still rests")
        expect(!floor.contains(CGPoint(x: 800, y: 40)), "well above the floor does not rest")
        expect(!floor.contains(CGPoint(x: 5000, y: 0)), "outside the span does not rest")

        // The tolerance test is the whole reason this is not Shimeji's integer
        // equality: a fractional anchor from a scaled display still lands.
        expect(floor.contains(CGPoint(x: 800, y: 0.3)),
               "fractional anchors must rest — HiDPI would break exact equality")
    }

    static func testCrossingIsDirectional() {
        let floor = Surface(id: .workAreaBottom(displayID: 1), kind: .floor,
                            position: 0, span: 0...1728)
        expect(floor.isCrossed(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 10, y: -10)),
               "descending through a floor crosses it")
        expect(!floor.isCrossed(from: CGPoint(x: 10, y: -10), to: CGPoint(x: 10, y: 50)),
               "rising through a floor must not count, or a jump re-lands instantly")
        expect(!floor.isCrossed(from: CGPoint(x: 2000, y: 50), to: CGPoint(x: 2000, y: -10)),
               "descending outside the span misses")

        let ceiling = Surface(id: .workAreaTop(displayID: 1), kind: .ceiling,
                              position: 100, span: 0...1728)
        expect(ceiling.isCrossed(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 10, y: 150)),
               "rising through a ceiling crosses it")
        expect(!ceiling.isCrossed(from: CGPoint(x: 10, y: 150), to: CGPoint(x: 10, y: 50)),
               "descending through a ceiling must not count")
    }

    static func testFirstCrossingPicksNearest() {
        let world = SurfaceSet.workArea(CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 1)
        // Travelling down-left into the corner: the wall is nearer than the floor.
        let hit = world.firstCrossing(from: CGPoint(x: 10, y: 50),
                                      to: CGPoint(x: -20, y: -20))
        expect(hit != nil, "corner travel should hit something")
        expect(hit!.surface.id == .workAreaLeft(displayID: 1),
               "nearest surface wins; got \(hit!.surface.id)")
    }

    // MARK: - Gravity, against Shimeji's own numbers

    /// Shimeji's fall, transcribed literally from action/Fall.java, in its own
    /// units: y-down, one 40ms tick per iteration, integer gravity 2.
    static func shimejiFall(ticks: Int) -> (x: Double, y: Double, vx: Double, vy: Double) {
        var vx = 0.0, vy = 0.0, x = 0.0, y = 0.0
        for _ in 0..<ticks {
            vx -= vx * 0.05
            vy = vy - vy * 0.1 + 2.0
            x += vx
            y += vy
        }
        return (x, y, vx, vy)
    }

    /// Sanity check that our constants land in Shimeji's regime — NOT an
    /// equality check, because exact agreement is impossible by construction.
    ///
    /// Shimeji integrates semi-implicit Euler at a fixed 40ms tick. That
    /// discretisation carries an O(dt) overshoot which is part of its
    /// trajectory, not an error to be reproduced: a fall of duration T
    /// overshoots the true curve by roughly `a·T·dt/2`, which at 40ms is
    /// substantial. We integrate the closed form instead, because reproducing
    /// Euler's overshoot at every step size and being frame-rate independent
    /// are mutually exclusive, and frame-rate independence is the design goal
    /// (docs/companion/03-runtime-architecture.md §4.4).
    ///
    /// So this asserts the two agree in shape and stay within ~20% over a real
    /// fall — enough to catch a botched unit conversion (which would be off by
    /// a factor of 25 or 625), and deliberately not tight enough to pin us to
    /// Euler. Absolute feel gets tuned against real dragging in P0 block 3.
    static func testGravityIsInShimejiRegime() {
        let dt: CGFloat = 1.0 / 25
        let openWorld = SurfaceSet([])

        for ticks in [5, 25, 50] {
            var integrator = CompanionIntegrator()
            var anchor = CGPoint.zero
            for _ in 0..<ticks {
                guard case .airborne(let next) = integrator.step(from: anchor, dt: dt, in: openWorld) else {
                    preconditionFailure("open world should never contact")
                }
                anchor = next
            }
            // Ours is y-up, Shimeji's y-down, so displacement negates.
            let expected = -CGFloat(shimejiFall(ticks: ticks).y)
            expectClose(anchor.y, expected, max(2, abs(expected) * 0.20),
                        "fall after \(ticks) ticks should sit in Shimeji's regime")
        }
    }

    /// Terminal velocity is a property of the constants alone, independent of
    /// integration scheme, so this one CAN be checked exactly. Shimeji's
    /// `v = 0.9v + 2` settles at 20 px/tick = 500 px/s.
    static func testTerminalVelocityMatchesShimejiExactly() {
        let openWorld = SurfaceSet([])
        var integrator = CompanionIntegrator()
        var anchor = CGPoint.zero
        for _ in 0..<600 {
            guard case .airborne(let next) = integrator.step(from: anchor, dt: 1.0 / 60, in: openWorld) else {
                preconditionFailure("open world should never contact")
            }
            anchor = next
        }
        expectClose(integrator.velocity.dy, -500, 1,
                    "terminal velocity must equal Shimeji's 20 px/tick")
    }

    /// The property the entire per-second design exists to buy: the same
    /// trajectory regardless of how finely the second is divided. Shimeji cannot
    /// do this at all — its offsets are per-tick, so changing frame rate changes
    /// how far everything moves.
    ///
    /// Tolerance is tight on purpose. Closed-form integration should agree to
    /// floating-point noise; anything looser would hide a regression back to
    /// Euler, which differs by ~11% between 25fps and 60fps.
    static func testTrajectoryIsFrameRateIndependent() {
        let openWorld = SurfaceSet([])
        // Step counts are exact rather than accumulated, so this measures the
        // integrator rather than float drift in the loop counter.
        func fall(rate: Int, seconds: Int) -> CGPoint {
            var integrator = CompanionIntegrator(velocity: CGVector(dx: 300, dy: 200))
            var anchor = CGPoint.zero
            for _ in 0..<(rate * seconds) {
                guard case .airborne(let next) = integrator.step(from: anchor,
                                                                 dt: 1 / CGFloat(rate),
                                                                 in: openWorld) else {
                    preconditionFailure("open world should never contact")
                }
                anchor = next
            }
            return anchor
        }

        let at25 = fall(rate: 25, seconds: 1)
        let at60 = fall(rate: 60, seconds: 1)
        let at120 = fall(rate: 120, seconds: 1)

        expectClose(at60.y, at25.y, 0.01, "25fps vs 60fps fall must be identical")
        expectClose(at120.y, at60.y, 0.01, "60fps vs 120fps fall must be identical")
        expectClose(at120.x, at60.x, 0.01, "60fps vs 120fps drift must be identical")
    }

    // MARK: - Landing

    static func testFallLandsOnFloorNotThrough() {
        let world = SurfaceSet.workArea(CGRect(x: 0, y: 0, width: 1728, height: 1084), displayID: 1)
        var integrator = CompanionIntegrator()
        var anchor = CGPoint(x: 800, y: 400)

        var landed: SurfaceID?
        for _ in 0..<600 {
            switch integrator.step(from: anchor, dt: 1.0 / 60, in: world) {
            case .airborne(let next):
                anchor = next
                expect(anchor.y >= -CompanionPhysics.surfaceTolerance,
                       "must never end a frame below the floor (tunnelled to \(anchor.y))")
            case .contacted(let id, let point):
                landed = id
                anchor = point
            }
            if landed != nil { break }
        }
        expect(landed == .workAreaBottom(displayID: 1), "a fall should land on the work-area floor")
        expectClose(anchor.y, 0, 0.001, "landing anchor sits exactly on the floor")
    }

    /// The tunnelling case Shimeji needed its 80px probe for. A companion thrown
    /// hard downward covers more than a frame's worth of distance in one step;
    /// swept crossing has to catch it.
    static func testFastThrowCannotTunnel() {
        let world = SurfaceSet.workArea(CGRect(x: 0, y: 0, width: 1728, height: 1084), displayID: 1)
        var integrator = CompanionIntegrator(velocity: CGVector(dx: 0, dy: -40000))
        let anchor = CGPoint(x: 800, y: 300)

        switch integrator.step(from: anchor, dt: 1.0 / 60, in: world) {
        case .contacted(let id, let point):
            expect(id == .workAreaBottom(displayID: 1), "should contact the floor")
            expectClose(point.y, 0, 0.001, "contact point is on the floor")
        case .airborne(let next):
            preconditionFailure("tunnelled straight through the floor to \(next)")
        }
    }

    static func testWallContactSticksThenSlidesWithoutPassingTheFloor() {
        let span: ClosedRange<CGFloat> = 0...900

        expectClose(
            CompanionWallSlide.nextY(currentY: 640, attachedSeconds: 0.20,
                                     dt: 1.0 / 60, span: span),
            640, 0.001,
            "a fresh wall contact should visibly stick before it starts sliding")

        let sliding = CompanionWallSlide.nextY(
            currentY: 640, attachedSeconds: CompanionWallSlide.stickDuration + 0.10,
            dt: 0.5, span: span)
        expect(sliding < 640 && sliding > 600,
               "after the pause it should descend slowly, got \(sliding)")

        let atBottom = CompanionWallSlide.nextY(
            currentY: 4, attachedSeconds: CompanionWallSlide.stickDuration + 1,
            dt: 1, span: span)
        expectClose(atBottom, span.lowerBound, 0.001,
                    "wall slide must stop at the floor instead of leaving the screen")
    }

    static func testReleaseAlreadyOutsideSnapsToTheNearestBoundary() {
        let world = SurfaceSet.workArea(
            CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 7)

        guard let right = world.workAreaContact(forOutside: CGPoint(x: 112, y: 60)) else {
            preconditionFailure("an anchor released beyond the right edge needs immediate contact")
        }
        expect(right.surface.id == .workAreaRight(displayID: 7),
               "an outside release should attach to the nearest right wall")
        expect(right.point == CGPoint(x: 100, y: 60),
               "the anchor should be pulled back exactly onto that wall")

        expect(world.workAreaContact(forOutside: CGPoint(x: 50, y: 60)) == nil,
               "an ordinary in-bounds release must retain its throw velocity")
    }

    static func testHugeTimeStepIsClamped() {
        let world = SurfaceSet([])
        var integrator = CompanionIntegrator()
        // A stalled main thread or a display wake can hand us a whole second.
        guard case .airborne(let next) = integrator.step(from: .zero, dt: 5, in: world) else {
            preconditionFailure("open world should never contact")
        }
        expect(abs(next.y) < 100, "a 5s frame must be clamped, not teleport (moved \(next.y))")
    }

    static func testGravityScaleZeroFloats() {
        var integrator = CompanionIntegrator(gravityScale: 0)
        guard case .airborne(let next) = integrator.step(from: .zero, dt: 1.0 / 60, in: SurfaceSet([])) else {
            preconditionFailure("open world should never contact")
        }
        expectClose(next.y, 0, 0.001, "zero gravity scale should not fall")
    }

    // MARK: - Cursor

    /// The forgiving-flick property, stated as a test: a cursor that stalls for
    /// one sample before release must still carry most of its speed.
    static func testCursorVelocitySurvivesAStall() {
        var tracker = CursorTracker(position: .zero)
        let dt: CGFloat = 1.0 / 60
        for index in 1...10 {
            tracker.update(to: CGPoint(x: CGFloat(index) * 20, y: 0), dt: dt)
        }
        let moving = tracker.velocity.dx
        expect(moving > 0, "a moving cursor should have positive velocity")

        // One frame where the cursor did not move, then release.
        tracker.update(to: CGPoint(x: 200, y: 0), dt: dt)
        let afterStall = tracker.releaseVelocity().dx
        expect(afterStall > moving * 0.4,
               "a one-frame stall must not kill the throw (was \(moving), now \(afterStall))")
    }

    static func testCursorIgnoresZeroDelta() {
        var tracker = CursorTracker(position: CGPoint(x: 10, y: 10))
        tracker.update(to: CGPoint(x: 99, y: 99), dt: 0)
        expect(tracker.position == CGPoint(x: 99, y: 99), "position still tracks with dt 0")
        expect(tracker.velocity == .zero, "dt 0 must not produce infinite velocity")
    }

    // MARK: - Drag spring

    /// Shimeji's dangle, transcribed from action/Dragged.java.
    static func shimejiFoot(target: Double, ticks: Int) -> Double {
        var footX = 0.0, footDx = 0.0
        for _ in 0..<ticks {
            footDx = (footDx + (target - footX) * 0.1) * 0.8
            footX += footDx
        }
        return footX
    }

    static func testDragSpringMatchesShimejiAt25fps() {
        let target: CGFloat = 100
        let dt: CGFloat = 1.0 / 25
        for ticks in [5, 15, 40] {
            var spring = DragSpring()
            for _ in 0..<ticks { spring.step(target: target, dt: dt) }
            let reference = CGFloat(shimejiFoot(target: 100, ticks: ticks))
            expectClose(spring.offset, reference, max(6, abs(reference) * 0.16),
                        "dangle after \(ticks) ticks should track Shimeji")
        }
    }

    /// The spring must overshoot. A critically damped follow would read as a
    /// stiff object; the overshoot is what makes a held companion feel alive.
    static func testDragSpringOvershoots() {
        var spring = DragSpring()
        let target: CGFloat = 100
        var peak: CGFloat = 0
        for _ in 0..<400 {
            spring.step(target: target, dt: 1.0 / 60)
            peak = max(peak, spring.offset)
        }
        expect(peak > target, "spring should overshoot its target (peaked at \(peak))")
        expectClose(spring.offset, target, 1, "and then settle on it")
    }

    // MARK: - Device pixel snapping

    static func testDevicePixelSnapping() {
        let point = CGPoint(x: 10.3, y: 20.8)
        expect(devicePixelSnapped(point, scale: 1) == CGPoint(x: 10, y: 21), "1x snaps to whole pixels")
        expect(devicePixelSnapped(point, scale: 2) == CGPoint(x: 10.5, y: 21), "2x snaps to half pixels")
        expect(devicePixelSnapped(point, scale: 0) == point, "invalid scale is a no-op")
    }

    // MARK: - Recovery

    /// The bug this exists for: the companion layer covers screen.frame while
    /// the floor sits at visibleFrame.minY, so the strip behind the Dock is
    /// below the floor. A floor is only crossed while descending through its y,
    /// and from underneath there is nothing left to descend through — so a
    /// companion thrown down there falls forever and is gone.
    static func testCompanionThrownBelowTheFloorIsRecovered() {
        let workArea = CGRect(x: 0, y: 70, width: 1728, height: 1014)   // 70pt Dock strip
        let inTheDockStrip = CGPoint(x: 800, y: 20)
        guard let recovered = CompanionRecovery.recoveredAnchor(for: inTheDockStrip,
                                                                workAreas: [workArea]) else {
            preconditionFailure("a companion below the floor must be recovered")
        }
        expect(recovered.y == workArea.minY, "it comes back onto the floor")
        expect(recovered.x == 800, "and keeps its horizontal position")
    }

    static func testCompanionThrownOffAnySideIsRecovered() {
        let workArea = CGRect(x: 0, y: 70, width: 1728, height: 1014)
        for lost in [CGPoint(x: -400, y: 500), CGPoint(x: 4000, y: 500),
                     CGPoint(x: 800, y: -900), CGPoint(x: 800, y: 5000)] {
            guard let recovered = CompanionRecovery.recoveredAnchor(for: lost,
                                                                    workAreas: [workArea]) else {
                preconditionFailure("\(lost) should be recovered")
            }
            expect(workArea.insetBy(dx: -1, dy: -1).contains(recovered),
                   "recovery lands inside the work area, got \(recovered)")
        }
    }

    /// Recovery must not fire on a companion that is simply standing there, or
    /// it would teleport constantly.
    static func testCompanionInsideTheWorkAreaIsLeftAlone() {
        let workArea = CGRect(x: 0, y: 70, width: 1728, height: 1014)
        for fine in [CGPoint(x: 800, y: 500),
                     CGPoint(x: 800, y: workArea.minY),      // resting on the floor
                     CGPoint(x: workArea.maxX - 4, y: 300),  // walked to the right edge
                     CGPoint(x: 800, y: workArea.maxY)] {    // at the ceiling
            expect(CompanionRecovery.recoveredAnchor(for: fine, workAreas: [workArea]) == nil,
                   "\(fine) is legal and must not be moved")
        }
    }

    /// Thrown off the bottom of a second display, it should come back there
    /// rather than jumping to the primary one.
    static func testRecoveryPrefersTheNearestDisplay() {
        let primary = CGRect(x: 0, y: 70, width: 1728, height: 1014)
        let secondary = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        guard let recovered = CompanionRecovery.recoveredAnchor(
            for: CGPoint(x: 3000, y: -200), workAreas: [primary, secondary]) else {
            preconditionFailure("should be recovered")
        }
        expect(recovered.x > primary.maxX, "it returns to the display it fell from, got \(recovered)")
        expect(recovered.y == secondary.minY, "onto that display's floor")
    }

    static func testRecoveryWithNoDisplaysIsANoOp() {
        expect(CompanionRecovery.recoveredAnchor(for: .zero, workAreas: []) == nil,
               "with no work areas there is nowhere to recover to")
    }

    static func main() {
        testCompanionThrownBelowTheFloorIsRecovered()
        testCompanionThrownOffAnySideIsRecovered()
        testCompanionInsideTheWorkAreaIsLeftAlone()
        testRecoveryPrefersTheNearestDisplay()
        testRecoveryWithNoDisplaysIsANoOp()
        testWorkAreaSurfaces()
        testCrossingIsDirectional()
        testFirstCrossingPicksNearest()
        testGravityIsInShimejiRegime()
        testTerminalVelocityMatchesShimejiExactly()
        testTrajectoryIsFrameRateIndependent()
        testFallLandsOnFloorNotThrough()
        testFastThrowCannotTunnel()
        testWallContactSticksThenSlidesWithoutPassingTheFloor()
        testReleaseAlreadyOutsideSnapsToTheNearestBoundary()
        testHugeTimeStepIsClamped()
        testGravityScaleZeroFloats()
        testCursorVelocitySurvivesAStall()
        testCursorIgnoresZeroDelta()
        testDragSpringMatchesShimejiAt25fps()
        testDragSpringOvershoots()
        testDevicePixelSnapping()
        print("companion physics: all assertions passed")
    }
}
