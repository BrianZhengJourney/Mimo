// sources: companion_expression.swift companion_behavior.swift companion_director.swift
import CoreGraphics
import Foundation

@main
struct CompanionDirectorTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func makePack(_ json: [String: Any]) -> CompanionBehaviorPack {
        try! CompanionBehaviorPack.load(json)
    }

    static func grounded(_ x: Double = 500, mood: String = "idle") -> CompanionSnapshot {
        var snapshot = CompanionSnapshot()
        snapshot.state = "grounded"
        snapshot.anchorX = x
        snapshot.mood = mood
        snapshot.workAreaLeft = 0
        snapshot.workAreaRight = 1440
        return snapshot
    }

    /// A pack with one stay and one move, both grounded.
    static let walkPack: [String: Any] = [
        "schemaVersion": 1,
        "actions": [
            ["name": "Stand", "type": "stay", "requires": "grounded", "duration": "2.0",
             "animations": [["poses": [["frame": 0, "hold": 1.0, "velocity": [0, 0]]]]]],
            ["name": "Walk", "type": "move", "requires": "grounded",
             "targetX": "800", "duration": "20",
             "animations": [["poses": [["frame": 1, "hold": 0.2, "velocity": [-50, 0]]]]]],
            ["name": "Fall", "type": "embedded", "requires": "airborne", "impl": "fall"],
            ["name": "Dragged", "type": "embedded", "requires": "held", "impl": "dragged"],
        ],
        "behaviors": [
            ["name": "Stand", "frequency": 100, "when": "#{self.state == 'grounded'}"],
            ["name": "Walk", "frequency": 100, "when": "#{self.state == 'grounded'}"],
            ["name": "Fall", "frequency": 100, "when": "#{self.state == 'airborne'}"],
            ["name": "Dragged", "frequency": 100, "when": "#{self.state == 'held'}"],
        ],
    ]

    // MARK: - Selection and running

    static func testPicksABehaviorAndRunsIt() {
        // roll 0.1 of 200 total lands in Stand's bucket.
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.1 })
        _ = director.update(dt: 0.016, snapshot: grounded())
        expect(director.currentBehaviorName == "Stand", "should have selected Stand")
    }

    static func testStayEndsAfterItsDuration() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.1 })
        _ = director.update(dt: 0.5, snapshot: grounded())
        expect(director.currentBehaviorName == "Stand", "Stand starts")
        for _ in 0..<4 { _ = director.update(dt: 0.5, snapshot: grounded()) }
        // 2.0s duration elapsed; the next update must have reselected.
        expect(director.elapsed < 2.0, "a finished action must be replaced, not run forever")
    }

    /// The pose supplies speed; the action supplies direction. An authored
    /// leftward walk cycle must still walk right when the target is to the
    /// right — same reason Shimeji authors every cycle leftward and mirrors it.
    static func testMoveWalksTowardTheTargetNotThePoseDirection() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.9 })
        let intent = director.update(dt: 0.016, snapshot: grounded(500))
        expect(director.currentBehaviorName == "Walk", "should have selected Walk")
        expect(intent.velocity.dx > 0,
               "target 800 is right of 500, so travel must be rightward despite a -50 pose")
        expect(intent.facingRight, "and it should face the way it is going")

        let fromRight = CompanionDirector(pack: makePack(walkPack), random: { 0.9 })
        let leftward = fromRight.update(dt: 0.016, snapshot: grounded(1200))
        expect(leftward.velocity.dx < 0, "target 800 is left of 1200, so travel is leftward")
        expect(!leftward.facingRight, "and facing flips")
    }

    static func testMoveEndsOnArrival() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.9 })
        _ = director.update(dt: 0.016, snapshot: grounded(500))
        expect(director.currentBehaviorName == "Walk", "Walk starts")
        // Arrive at the target; the action should not still be running after.
        _ = director.update(dt: 0.016, snapshot: grounded(800))
        _ = director.update(dt: 0.016, snapshot: grounded(800))
        expect(director.elapsed < 0.05, "arriving must end the move, not loop on the spot")
    }

    static func testPoseFrameIsReported() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.9 })
        let intent = director.update(dt: 0.016, snapshot: grounded(500))
        expect(intent.frame == 1, "the authored pose frame is what gets drawn")
    }

    static func testPoseStripIsReported() {
        let pack = makePack([
            "schemaVersion": 2,
            "actions": [[
                "name": "Rest", "type": "stay", "requires": "grounded", "duration": "1",
                "animations": [["poses": [["strip": "rest", "frame": 9, "hold": 1.0]]]],
            ]],
            "behaviors": [["name": "Rest", "frequency": 100]],
        ])
        let intent = CompanionDirector(pack: pack, availableStrips: ["rest"], random: { 0.5 })
            .update(dt: 0.016, snapshot: grounded())
        expect(intent.strip == "rest", "the director carries the named strip to the runtime")
        expect(intent.frame == 9, "the frame stays local to the named strip")
    }

    static func testMissingStripBehaviorIsNotSelected() {
        let pack = makePack([
            "schemaVersion": 2,
            "actions": [
                ["name": "Stand", "type": "stay", "requires": "grounded", "duration": "1",
                 "animations": [["poses": [["frame": 0]]]]],
                ["name": "Rest", "type": "stay", "requires": "grounded", "duration": "1",
                 "animations": [["poses": [["strip": "rest", "frame": 0]]]]],
            ],
            "behaviors": [
                ["name": "Stand", "frequency": 1],
                ["name": "Rest", "frequency": 1000],
            ],
        ])
        let director = CompanionDirector(pack: pack, availableStrips: [], random: { 0.99 })
        _ = director.update(dt: 0.016, snapshot: grounded())
        expect(director.currentBehaviorName == "Stand",
               "missing strip actions stay out of the director's urn")
    }

    // MARK: - The interruption rule

    /// Being grabbed outranks whatever the pack was doing. Shimeji's one cold
    /// rule: the companion never ignores your hand.
    static func testGrabInterruptsImmediately() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.9 })
        _ = director.update(dt: 0.016, snapshot: grounded(500))
        expect(director.currentBehaviorName == "Walk", "walking first")

        var held = grounded(500)
        held.state = "held"
        let intent = director.update(dt: 0.016, snapshot: held)
        expect(director.currentBehaviorName == "Dragged", "being grabbed takes over at once")
        expect(intent.embedded == "dragged", "and hands off to the native drag")
    }

    static func testLosingTheGroundSwitchesToFall() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.1 })
        _ = director.update(dt: 0.016, snapshot: grounded(500))
        expect(director.currentBehaviorName == "Stand", "standing first")

        var airborne = grounded(500)
        airborne.state = "airborne"
        let intent = director.update(dt: 0.016, snapshot: airborne)
        expect(director.currentBehaviorName == "Fall",
               "an action whose required state no longer holds ends at once")
        expect(intent.embedded == "fall", "and hands off to the native fall")
    }

    /// A grounded action must never be selected while airborne. Shimeji
    /// discovers this by throwing out of a tick; the requirement makes it a
    /// filter instead.
    static func testGroundedActionsAreNotSelectedWhileAirborne() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.1 })
        var airborne = grounded(500)
        airborne.state = "airborne"
        for _ in 0..<20 {
            _ = director.update(dt: 0.1, snapshot: airborne)
            expect(director.currentBehaviorName == "Fall" || director.currentBehaviorName == nil,
                   "only airborne behaviors may run while airborne, got "
                   + "\(director.currentBehaviorName ?? "nil")")
        }
    }

    // MARK: - Attached

    static let clingPack: [String: Any] = [
        "schemaVersion": 1,
        "actions": [
            ["name": "Stand", "type": "stay", "requires": "grounded", "duration": "2.0",
             "animations": [["poses": [["frame": 0, "hold": 1.0]]]]],
            ["name": "Cling", "type": "stay", "requires": "attached", "duration": "1.0",
             "animations": [["poses": [["frame": 1, "hold": 1.0]]]]],
        ],
        "behaviors": [
            ["name": "Stand", "frequency": 100, "when": "#{self.state == 'grounded'}"],
            ["name": "Cling", "frequency": 100,
             "when": "#{self.state == 'attached' && self.surface == 'wall'}",
             "next": ["additive": false, "refs": []]],
        ],
    ]

    static func attached(surface: String = "wall") -> CompanionSnapshot {
        var snapshot = CompanionSnapshot()
        snapshot.state = "attached"
        snapshot.surface = surface
        return snapshot
    }

    static func testAttachedSelectsOnlyAttachedBehaviors() {
        let director = CompanionDirector(pack: makePack(clingPack), random: { 0.5 })
        _ = director.update(dt: 0.016, snapshot: attached())
        expect(director.currentBehaviorName == "Cling",
               "on a wall, only the attached behavior is in the urn")
    }

    /// A behaviour gated to walls must not fire on a ceiling; with nothing
    /// selectable the director reports nil, which the runtime reads as
    /// "let go and fall".
    static func testCeilingWithNoBehaviorSelectsNothing() {
        let director = CompanionDirector(pack: makePack(clingPack), random: { 0.5 })
        _ = director.update(dt: 0.016, snapshot: attached(surface: "ceiling"))
        expect(director.currentBehaviorName == nil,
               "a wall-only pack has nothing to do on a ceiling")
    }

    /// `additive:false` with no refs is the authored way to end an attached
    /// episode: after the cling runs out, nothing is selected and the runtime
    /// detaches. `additive:true` would re-draw the cling from the pool forever.
    static func testEmptyNonAdditiveChainEndsTheEpisode() {
        let director = CompanionDirector(pack: makePack(clingPack), random: { 0.5 })
        _ = director.update(dt: 0.5, snapshot: attached())
        expect(director.currentBehaviorName == "Cling", "clinging first")
        _ = director.update(dt: 0.6, snapshot: attached())   // past the 1.0s duration
        _ = director.update(dt: 0.016, snapshot: attached())
        expect(director.currentBehaviorName == nil,
               "after the cling, the empty commitment selects nothing")
    }

    // MARK: - Reactions

    static let pokePack: [String: Any] = [
        "schemaVersion": 1,
        "actions": [
            ["name": "Stand", "type": "stay", "requires": "grounded", "duration": "60",
             "animations": [["poses": [["frame": 0, "hold": 1.0]]]]],
            ["name": "Poked", "type": "stay", "requires": "grounded", "duration": "0.9",
             "animations": [["poses": [["frame": 1, "hold": 1.0]]]]],
        ],
        "behaviors": [
            ["name": "Stand", "frequency": 100, "when": "#{self.state == 'grounded'}"],
            ["name": "Poked", "frequency": 0, "when": "#{self.state == 'grounded'}"],
        ],
        "reactions": ["click": "Poked"],
    ]

    static func testClickReactionInterruptsTheCurrentBehavior() {
        let director = CompanionDirector(pack: makePack(pokePack), random: { 0.5 })
        _ = director.update(dt: 0.016, snapshot: grounded())
        expect(director.currentBehaviorName == "Stand", "standing first")

        expect(director.trigger(reactionTo: "click", snapshot: grounded()),
               "a declared, legal reaction must trigger")
        expect(director.currentBehaviorName == "Poked", "the reaction takes over at once")
        let intent = director.update(dt: 0.016, snapshot: grounded())
        expect(intent.frame == 1, "and its pose is what gets drawn")
    }

    static func testReactionRunsItsCourseThenReturnsToThePool() {
        let director = CompanionDirector(pack: makePack(pokePack), random: { 0.5 })
        _ = director.trigger(reactionTo: "click", snapshot: grounded())
        // 0.5s steps rather than 0.3: three 0.3 steps sum to 0.899…, which
        // never reaches the 0.9s duration.
        for _ in 0..<4 { _ = director.update(dt: 0.5, snapshot: grounded()) }
        expect(director.currentBehaviorName == "Stand",
               "after the reaction elapses, ordinary selection resumes")
    }

    static func testUndeclaredReactionReportsFalse() {
        let director = CompanionDirector(pack: makePack(pokePack), random: { 0.5 })
        expect(!director.trigger(reactionTo: "double-click", snapshot: grounded()),
               "an event the pack does not declare must report false so the "
               + "caller can fall back")
    }

    static func testReactionIllegalInThisStateReportsFalse() {
        let director = CompanionDirector(pack: makePack(pokePack), random: { 0.5 })
        var airborne = grounded()
        airborne.state = "airborne"
        expect(!director.trigger(reactionTo: "click", snapshot: airborne),
               "a grounded reaction cannot fire mid-air")
        expect(director.currentBehaviorName != "Poked", "and nothing was hijacked")
    }

    // MARK: - Frozen values

    /// `${...}` resolves once when the action starts. Re-resolving per frame
    /// would re-roll a randomised duration forever and it would never elapse —
    /// the exact bug libshijima has, having collapsed $ and #.
    static func testRandomisedDurationIsFrozenAtStart() {
        var rolls: [Double] = [0.1, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9]
        var index = 0
        let pack = makePack([
            "schemaVersion": 1,
            "actions": [["name": "Stand", "type": "stay", "requires": "grounded",
                         "duration": "${1 + random() * 10}",
                         "animations": [["poses": [["frame": 0, "hold": 1.0]]]]]],
            "behaviors": [["name": "Stand", "frequency": 100]],
        ])
        let director = CompanionDirector(pack: pack, random: {
            defer { index += 1 }
            return rolls[min(index, rolls.count - 1)]
        })
        _ = director.update(dt: 0.1, snapshot: grounded())
        let first = director.elapsed
        _ = director.update(dt: 0.1, snapshot: grounded())
        expect(director.elapsed > first,
               "elapsed must advance; a re-rolled duration would keep resetting it")
        _ = rolls
    }

    // MARK: - Mood gating (D6)

    /// The product decision that separates this from a generic desktop pet: the
    /// companion stays quiet during deep work. Expressed as a condition on the
    /// semantic layer, not a global if.
    static func testDeepWorkGatesRoamingOut() {
        let pack = makePack([
            "schemaVersion": 1,
            "actions": [
                ["name": "Walk", "type": "move", "requires": "grounded",
                 "targetX": "800", "duration": "5",
                 "animations": [["poses": [["frame": 0, "hold": 0.2, "velocity": [40, 0]]]]]],
                ["name": "QuietBreathe", "type": "stay", "requires": "grounded",
                 "duration": "10",
                 "animations": [["poses": [["frame": 0, "hold": 3.0]]]]],
            ],
            "behaviors": [
                ["name": "Walk", "frequency": 100,
                 "when": "#{self.state == 'grounded' && mimo.mood != 'deepWork'}"],
                ["name": "QuietBreathe", "frequency": 100,
                 "when": "#{self.state == 'grounded' && mimo.mood == 'deepWork'}"],
            ],
        ])

        for roll in [0.05, 0.5, 0.95] {
            let director = CompanionDirector(pack: pack, random: { roll })
            _ = director.update(dt: 0.016, snapshot: grounded(500, mood: "deepWork"))
            expect(director.currentBehaviorName == "QuietBreathe",
                   "deep work must leave only the quiet set, got "
                   + "\(director.currentBehaviorName ?? "nil") at roll \(roll)")
        }

        let idle = CompanionDirector(pack: pack, random: { 0.5 })
        _ = idle.update(dt: 0.016, snapshot: grounded(500, mood: "idle"))
        expect(idle.currentBehaviorName == "Walk", "roaming returns when idle")
    }

    static func testShippedPackKeepsLookingBackUntilTheContextEnds() throws {
        let data = try Data(contentsOf: URL(
            fileURLWithPath: "mac/assets/behavior/default.json"))
        let pack = try CompanionBehaviorPack.load(data: data)
        let director = CompanionDirector(pack: pack, random: { 0.5 })
        var snapshot = grounded(500, mood: "reflecting")
        _ = director.update(dt: 0.016, snapshot: snapshot)
        expect(director.currentBehaviorName == "Reflecting",
               "the visible Today Journal should select only the quiet looking-back loop")
        expect(director.trigger(reactionTo: "journalOpened", snapshot: snapshot),
               "opening Today Journal should begin with one explicit shared glance")
        expect(director.currentBehaviorName == "ReflectTogether", "the reaction takes over once")
        _ = director.update(dt: 8.1, snapshot: snapshot)
        _ = director.update(dt: 0.016, snapshot: snapshot)
        expect(director.currentBehaviorName == "Reflecting",
               "after the opening beat, the companion must keep accompanying the session")
        snapshot.mood = "deepWork"
        director.reset()
        _ = director.update(dt: 0.016, snapshot: snapshot)
        expect(director.currentBehaviorName == "QuietBreathe",
               "closing the journal can restore the underlying deep-work behavior")
    }

    // MARK: - Degenerate packs

    /// Nothing drawable leaves the companion idle. Shimeji teleports the mascot
    /// above the screen and drops it, which is self-healing but silent — an
    /// authoring error shows up as rain.
    static func testNoDrawableBehaviorLeavesItIdleNotFalling() {
        let pack = makePack([
            "schemaVersion": 1,
            "actions": [["name": "Stand", "type": "stay", "requires": "grounded",
                         "animations": [["poses": [["frame": 0, "hold": 1.0]]]]]],
            "behaviors": [["name": "Stand", "frequency": 100,
                           "when": "#{mimo.mood == 'never-matches'}"]],
        ])
        let director = CompanionDirector(pack: pack, random: { 0.5 })
        let intent = director.update(dt: 0.016, snapshot: grounded())
        expect(director.currentBehaviorName == nil, "nothing should be selected")
        expect(intent.velocity == .zero, "and the companion should simply stand still")
        expect(intent.embedded == nil, "with no surprise handoff")
    }

    static func testResetForcesReselection() {
        let director = CompanionDirector(pack: makePack(walkPack), random: { 0.1 })
        _ = director.update(dt: 0.016, snapshot: grounded())
        expect(director.currentBehaviorName == "Stand", "running something")
        director.reset()
        expect(director.currentBehaviorName == nil, "reset clears the current behavior")
    }

    static func main() throws {
        testPicksABehaviorAndRunsIt()
        testStayEndsAfterItsDuration()
        testMoveWalksTowardTheTargetNotThePoseDirection()
        testMoveEndsOnArrival()
        testPoseFrameIsReported()
        testPoseStripIsReported()
        testMissingStripBehaviorIsNotSelected()
        testGrabInterruptsImmediately()
        testLosingTheGroundSwitchesToFall()
        testGroundedActionsAreNotSelectedWhileAirborne()
        testAttachedSelectsOnlyAttachedBehaviors()
        testCeilingWithNoBehaviorSelectsNothing()
        testEmptyNonAdditiveChainEndsTheEpisode()
        testClickReactionInterruptsTheCurrentBehavior()
        testReactionRunsItsCourseThenReturnsToThePool()
        testUndeclaredReactionReportsFalse()
        testReactionIllegalInThisStateReportsFalse()
        testRandomisedDurationIsFrozenAtStart()
        testDeepWorkGatesRoamingOut()
        try testShippedPackKeepsLookingBackUntilTheContextEnds()
        testNoDrawableBehaviorLeavesItIdleNotFalling()
        testResetForcesReselection()
        print("companion director: all assertions passed")
    }
}
