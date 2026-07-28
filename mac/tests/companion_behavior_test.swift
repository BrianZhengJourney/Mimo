// sources: companion_expression.swift companion_behavior.swift
import CoreGraphics
import Foundation

@main
struct CompanionBehaviorTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func bag(_ pairs: [String: CompanionValue] = [:]) -> CompanionVariableBag {
        CompanionVariableBag(values: pairs)
    }

    static func pack(_ json: [String: Any]) throws -> CompanionBehaviorPack {
        try CompanionBehaviorPack.load(json)
    }

    /// Minimal valid pack: one grounded stay action, one behaviour.
    static func basicPack(behaviors: [[String: Any]],
                          actions: [[String: Any]]? = nil) -> [String: Any] {
        [
            "schemaVersion": 1,
            "actions": actions ?? [
                ["name": "Stand", "type": "stay", "requires": "grounded"],
                ["name": "Walk", "type": "move", "requires": "grounded"],
                ["name": "Sit", "type": "stay", "requires": "grounded"],
                ["name": "Fall", "type": "embedded", "requires": "airborne", "impl": "fall"],
            ],
            "behaviors": behaviors,
        ]
    }

    // MARK: - Loading

    static func testLoadsActionsAndBehaviors() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100],
            ["name": "Walk", "frequency": 50],
        ]))
        expect(loaded.behavior(named: "Stand") != nil, "Stand loaded")
        expect(loaded.behavior(named: "Walk")?.frequency == 50, "frequency parsed")
        expect(loaded.action(named: "Walk")?.kind == .move, "action kind parsed")
        expect(loaded.action(named: "Fall")?.implementation == "fall", "embedded impl parsed")
    }

    static func testActionDefaultsToBehaviorName() throws {
        let loaded = try pack(basicPack(behaviors: [["name": "Stand", "frequency": 100]]))
        expect(loaded.behavior(named: "Stand")?.actionName == "Stand",
               "a behavior with no explicit action uses its own name")
    }

    static func testPosesParseInSecondsAndPixelsPerSecond() throws {
        let loaded = try pack(basicPack(
            behaviors: [["name": "Stand", "frequency": 100]],
            actions: [[
                "name": "Stand", "type": "stay", "requires": "grounded",
                "animations": [["poses": [
                    ["frame": 0, "hold": 0.9, "velocity": [0, 0]],
                    ["frame": 1, "hold": 0.12, "velocity": [-40, 0]],
                ]]],
            ]]))
        let animation = loaded.action(named: "Stand")!.animations.first!
        expect(animation.poses.count == 2, "two poses")
        expect(abs(animation.totalDuration - 1.02) < 0.001, "durations sum in seconds")
        expect(animation.poses[1].velocity.dx == -40, "velocity is px/second")
    }

    static func testSchemaTwoPoseNamesAnActionStrip() throws {
        var json = basicPack(
            behaviors: [["name": "Stand", "frequency": 100]],
            actions: [[
                "name": "Stand", "type": "stay", "requires": "grounded",
                "animations": [["poses": [["strip": "rest", "frame": 7, "hold": 0.4]]]],
            ]])
        json["schemaVersion"] = 2
        let pose = try pack(json).action(named: "Stand")!.animations[0].poses[0]
        expect(pose.strip == "rest", "schema v2 keeps the authored strip name")
        expect(pose.frame == 7, "the frame remains local to that strip")
    }

    static func testSchemaOneStillLoadsWithoutStripSemantics() throws {
        let loaded = try pack(basicPack(
            behaviors: [["name": "Stand", "frequency": 100]],
            actions: [[
                "name": "Stand", "type": "stay", "requires": "grounded",
                "animations": [["poses": [["strip": "rest", "frame": 2]]]],
            ]]))
        expect(loaded.action(named: "Stand")!.animations[0].poses[0].strip == nil,
               "v1 remains backward-compatible and does not acquire v2 meaning")
    }

    /// Frame lookup is `time % total`, matching Shimeji — there is no separate
    /// animation player holding its own cursor.
    static func testPoseLookupWrapsOnTotalDuration() throws {
        let loaded = try pack(basicPack(
            behaviors: [["name": "Stand", "frequency": 100]],
            actions: [[
                "name": "Stand", "type": "stay", "requires": "grounded",
                "animations": [["poses": [
                    ["frame": 0, "hold": 1.0], ["frame": 1, "hold": 1.0],
                ]]],
            ]]))
        let animation = loaded.action(named: "Stand")!.animations.first!
        expect(animation.pose(at: 0.5)?.frame == 0, "first pose early")
        expect(animation.pose(at: 1.5)?.frame == 1, "second pose later")
        expect(animation.pose(at: 2.5)?.frame == 0, "wraps around")
    }

    /// Multiple animation blocks are first-match-wins on condition, which is how
    /// one action becomes pose-reactive.
    static func testFirstMatchingAnimationWins() throws {
        let loaded = try pack(basicPack(
            behaviors: [["name": "Stand", "frequency": 100]],
            actions: [[
                "name": "Stand", "type": "stay", "requires": "grounded",
                "animations": [
                    ["when": "#{world.cursor.x < 100}", "poses": [["frame": 5, "hold": 1]]],
                    ["poses": [["frame": 0, "hold": 1]]],
                ],
            ]]))
        let action = loaded.action(named: "Stand")!
        expect(action.animation(for: bag(["world.cursor.x": .number(50)]))?.poses.first?.frame == 5,
               "conditional block wins when its condition passes")
        expect(action.animation(for: bag(["world.cursor.x": .number(900)]))?.poses.first?.frame == 0,
               "falls through to the unconditional block")
    }

    // MARK: - Load-time validation

    static func testUnknownActionIsRejected() {
        do {
            _ = try pack(basicPack(behaviors: [["name": "Ghost", "frequency": 100,
                                                "action": "NoSuchAction"]]))
            preconditionFailure("must reject a behavior pointing at a missing action")
        } catch let error as CompanionPackError {
            guard case .unknownAction(let name, _) = error else {
                preconditionFailure("expected unknownAction, got \(error)")
            }
            expect(name == "NoSuchAction", "the error names the missing action")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testUnknownChainTargetIsRejected() {
        do {
            _ = try pack(basicPack(behaviors: [[
                "name": "Stand", "frequency": 100,
                "next": ["additive": true, "refs": [["name": "Nowhere", "frequency": 10]]],
            ]]))
            preconditionFailure("must reject a chain to a missing behavior")
        } catch let error as CompanionPackError {
            guard case .unknownBehavior = error else {
                preconditionFailure("expected unknownBehavior, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// The check Shimeji has no equivalent of: a grounded action chaining to one
    /// that demands airborne can never fire, and there it would surface as a
    /// mascot mysteriously dropping out of the sky.
    static func testImpossibleChainIsRejectedAtLoad() {
        do {
            _ = try pack(basicPack(behaviors: [
                ["name": "Stand", "frequency": 100,
                 "next": ["additive": false, "refs": [["name": "Fall", "frequency": 100]]]],
                ["name": "Fall", "frequency": 0],
            ]))
            preconditionFailure("must reject grounded chaining to airborne")
        } catch let error as CompanionPackError {
            guard case .unreachableChain(let target, let owner, _) = error else {
                preconditionFailure("expected unreachableChain, got \(error)")
            }
            expect(target == "Fall" && owner == "Stand", "the error names both ends")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// Attachment is entered by physics on wall contact, never by chaining, so
    /// a chain into it from the ground — or out of it to a state the companion
    /// cannot be in when the chain is evaluated — is a load error, not a
    /// behaviour that silently never fires.
    static func testChainsInAndOutOfAttachedAreRejected() {
        let attachedActions: [[String: Any]] = [
            ["name": "Stand", "type": "stay", "requires": "grounded"],
            ["name": "Cling", "type": "stay", "requires": "attached"],
        ]
        do {
            _ = try pack(basicPack(behaviors: [
                ["name": "Stand", "frequency": 100,
                 "next": ["additive": false, "refs": [["name": "Cling", "frequency": 100]]]],
                ["name": "Cling", "frequency": 0],
            ], actions: attachedActions))
            preconditionFailure("must reject grounded chaining to attached")
        } catch let error as CompanionPackError {
            guard case .unreachableChain = error else {
                preconditionFailure("expected unreachableChain, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }

        do {
            _ = try pack(basicPack(behaviors: [
                ["name": "Cling", "frequency": 100,
                 "next": ["additive": false, "refs": [["name": "Stand", "frequency": 100]]]],
                ["name": "Stand", "frequency": 0],
            ], actions: attachedActions))
            preconditionFailure("must reject attached chaining to grounded")
        } catch let error as CompanionPackError {
            guard case .unreachableChain = error else {
                preconditionFailure("expected unreachableChain, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    // MARK: - Reactions

    static func testReactionsParseAndResolve() throws {
        var json = basicPack(behaviors: [["name": "Stand", "frequency": 100]])
        json["reactions"] = ["click": "Stand"]
        let loaded = try pack(json)
        expect(loaded.reactions["click"] == "Stand", "reaction event maps to its behavior")
    }

    static func testReactionToUnknownBehaviorIsRejected() {
        var json = basicPack(behaviors: [["name": "Stand", "frequency": 100]])
        json["reactions"] = ["click": "Nowhere"]
        do {
            _ = try pack(json)
            preconditionFailure("must reject a reaction pointing at a missing behavior")
        } catch let error as CompanionPackError {
            guard case .unknownReaction(let event, let behavior) = error else {
                preconditionFailure("expected unknownReaction, got \(error)")
            }
            expect(event == "click" && behavior == "Nowhere", "the error names both ends")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testBadExpressionNamesItsOwner() {
        do {
            _ = try pack(basicPack(behaviors: [
                ["name": "Stand", "frequency": 100, "when": "#{self.anchor.z > 0}"],
            ]))
            preconditionFailure("must reject an unknown variable in a condition")
        } catch let error as CompanionPackError {
            guard case .badExpression(_, let owner, _) = error else {
                preconditionFailure("expected badExpression, got \(error)")
            }
            expect(owner.contains("Stand"), "the error names the owning behavior")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testPackWithNothingSelectableIsRejected() {
        do {
            _ = try pack(basicPack(behaviors: [["name": "Stand", "frequency": 0]]))
            preconditionFailure("a pack where nothing can be drawn must not load")
        } catch let error as CompanionPackError {
            guard case .noReachableBehavior = error else {
                preconditionFailure("expected noReachableBehavior, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testUnsupportedSchemaIsRejected() {
        do {
            _ = try pack(["schemaVersion": 99, "actions": [], "behaviors": []])
            preconditionFailure("must reject a future schema rather than guess")
        } catch let error as CompanionPackError {
            guard case .unsupportedSchema = error else {
                preconditionFailure("expected unsupportedSchema, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// The pack we actually ship is data, not code — nothing validates it
    /// until app launch unless this does. Path is relative to the repo root,
    /// which is where test.sh runs every binary.
    static func testShippedDefaultPackLoads() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "mac/assets/behavior/default.json"))
        let loaded = try CompanionBehaviorPack.load(data: data)
        expect(loaded.schemaVersion == 2, "the shipped pack uses named action strips")
        expect(loaded.behavior(named: "ClingWall") != nil, "the wall cling is shipped")
        expect(loaded.behavior(named: "RestSettle") != nil, "the rest theater is shipped")
        expect(loaded.action(named: "ClingWall")?.animations[0].poses[0].strip == "wall",
               "wall contact selects the wall strip")
        let walkSpeed = abs(
            loaded.action(named: "WalkRight")?.animations[0].poses[0].velocity.dx ?? 0)
        expect((55...68).contains(walkSpeed),
               "the distance-driven two-step cycle advances at the calmer approved pace")
        expect(loaded.reactions["click"] == "Poked", "the click reaction is shipped")
    }

    // MARK: - Selection

    static func testWeightedSelectionFollowsTheRoll() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 30],
            ["name": "Walk", "frequency": 70],
        ]))
        let selector = CompanionBehaviorSelector(pack: loaded)
        // Total 100: [0,30) is Stand, [30,100) is Walk.
        expect(selector.selectNext(after: nil, source: bag(), random: { 0.1 })?.name == "Stand",
               "low roll picks the first bucket")
        expect(selector.selectNext(after: nil, source: bag(), random: { 0.5 })?.name == "Walk",
               "mid roll picks the second bucket")
        expect(selector.selectNext(after: nil, source: bag(), random: { 0.99 })?.name == "Walk",
               "high roll stays in range")
    }

    /// Gating is subtractive: a failed condition removes a behaviour from the
    /// urn rather than correcting after the fact.
    static func testConditionRemovesFromTheUrn() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100],
            ["name": "Walk", "frequency": 100, "when": "#{mimo.mood != 'deepWork'}"],
        ]))
        let selector = CompanionBehaviorSelector(pack: loaded)

        // During deep work only Stand remains, so every roll must return it.
        let deepWork = bag(["mimo.mood": .text("deepWork")])
        for roll in [0.0, 0.4, 0.9] {
            expect(selector.selectNext(after: nil, source: deepWork, random: { roll })?.name == "Stand",
                   "deep work leaves only Stand in the urn (roll \(roll))")
        }
        let idle = bag(["mimo.mood": .text("idle")])
        expect(selector.selectNext(after: nil, source: idle, random: { 0.9 })?.name == "Walk",
               "Walk returns to the urn when idle")
    }

    /// frequency 0 is not "disabled" — it is "reachable only by explicit
    /// reference", which is how a chain destination stays out of the ambient
    /// lottery.
    static func testZeroFrequencyIsReachableOnlyByChain() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100,
             "next": ["additive": false, "refs": [["name": "Sit", "frequency": 100]]]],
            ["name": "Sit", "frequency": 0],
        ]))
        let selector = CompanionBehaviorSelector(pack: loaded)

        for roll in [0.0, 0.5, 0.99] {
            expect(selector.selectNext(after: nil, source: bag(), random: { roll })?.name == "Stand",
                   "Sit never appears in the ambient draw")
        }
        let stand = loaded.behavior(named: "Stand")!
        expect(selector.selectNext(after: stand, source: bag(), random: { 0.5 })?.name == "Sit",
               "Sit is reachable through the chain")
    }

    /// The two chain modes, which is where the sense of intent comes from.
    /// additive false is a commitment; additive true is a nudge.
    static func testAdditiveChainUnionsWithThePool() throws {
        let hardChain = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100,
             "next": ["additive": false, "refs": [["name": "Sit", "frequency": 100]]]],
            ["name": "Sit", "frequency": 0],
            ["name": "Walk", "frequency": 100],
        ]))
        let hard = CompanionBehaviorSelector(pack: hardChain)
        let stand = hardChain.behavior(named: "Stand")!
        for roll in [0.0, 0.5, 0.99] {
            expect(hard.selectNext(after: stand, source: bag(), random: { roll })?.name == "Sit",
                   "a non-additive chain excludes the global pool entirely")
        }

        let softChain = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100,
             "next": ["additive": true, "refs": [["name": "Sit", "frequency": 100]]]],
            ["name": "Sit", "frequency": 0],
            ["name": "Walk", "frequency": 100],
        ]))
        let soft = CompanionBehaviorSelector(pack: softChain)
        let softStand = softChain.behavior(named: "Stand")!
        // Pool contributes Stand 100 + Walk 100, chain adds Sit 100 → 300.
        var seen = Set<String>()
        for roll in [0.1, 0.5, 0.9] {
            if let picked = soft.selectNext(after: softStand, source: bag(), random: { roll }) {
                seen.insert(picked.name)
            }
        }
        expect(seen.count > 1, "an additive chain competes with the pool, got \(seen)")
        expect(seen.contains("Sit"), "the chain target is still reachable")
    }

    /// A self-referencing high-weight chain against low-weight alternatives is
    /// how Shimeji gets a natural dwell time out of two lines of config, with no
    /// explicit timer.
    static func testSelfChainProducesDwell() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Sit", "frequency": 10,
             "next": ["additive": false, "refs": [
                ["name": "Sit", "frequency": 100],
                ["name": "Stand", "frequency": 1],
             ]]],
            ["name": "Stand", "frequency": 10],
        ]))
        let selector = CompanionBehaviorSelector(pack: loaded)
        let sit = loaded.behavior(named: "Sit")!

        var stayed = 0
        for step in 0..<100 {
            let roll = Double(step) / 100
            if selector.selectNext(after: sit, source: bag(), random: { roll })?.name == "Sit" {
                stayed += 1
            }
        }
        expect(stayed > 90, "a 100:1 self-chain should re-up almost always, got \(stayed)/100")
    }

    static func testNoCandidatesReturnsNil() throws {
        let loaded = try pack(basicPack(behaviors: [
            ["name": "Stand", "frequency": 100, "when": "#{mimo.mood == 'never'}"],
        ]))
        let selector = CompanionBehaviorSelector(pack: loaded)
        expect(selector.selectNext(after: nil, source: bag(["mimo.mood": .text("idle")]),
                                   random: { 0.5 }) == nil,
               "an empty urn returns nil so the caller can fall back deliberately")
    }

    static func testMissingActionStripRemovesBehaviorFromTheUrn() throws {
        var json = basicPack(
            behaviors: [
                ["name": "Stand", "frequency": 100],
                ["name": "Rest", "frequency": 100],
            ],
            actions: [
                ["name": "Stand", "type": "stay", "requires": "grounded"],
                ["name": "Rest", "type": "stay", "requires": "grounded",
                 "animations": [["poses": [["strip": "rest", "frame": 0]]]]],
            ])
        json["schemaVersion"] = 2
        let loaded = try pack(json)
        let selector = CompanionBehaviorSelector(pack: loaded)
        let available: (CompanionBehavior) -> Bool = { behavior in
            loaded.action(named: behavior.actionName)!.requiredStrips.isSubset(of: [])
        }
        for roll in [0.1, 0.9] {
            expect(selector.selectNext(after: nil, source: bag(), isAvailable: available,
                                       random: { roll })?.name == "Stand",
                   "a missing strip must not produce an invisible Rest behavior")
        }
    }

    static func main() throws {
        try testLoadsActionsAndBehaviors()
        try testActionDefaultsToBehaviorName()
        try testPosesParseInSecondsAndPixelsPerSecond()
        try testSchemaTwoPoseNamesAnActionStrip()
        try testSchemaOneStillLoadsWithoutStripSemantics()
        try testPoseLookupWrapsOnTotalDuration()
        try testFirstMatchingAnimationWins()
        testUnknownActionIsRejected()
        testUnknownChainTargetIsRejected()
        testImpossibleChainIsRejectedAtLoad()
        testChainsInAndOutOfAttachedAreRejected()
        try testReactionsParseAndResolve()
        testReactionToUnknownBehaviorIsRejected()
        testBadExpressionNamesItsOwner()
        testPackWithNothingSelectableIsRejected()
        testUnsupportedSchemaIsRejected()
        try testShippedDefaultPackLoads()
        try testWeightedSelectionFollowsTheRoll()
        try testConditionRemovesFromTheUrn()
        try testZeroFrequencyIsReachableOnlyByChain()
        try testAdditiveChainUnionsWithThePool()
        try testSelfChainProducesDwell()
        try testNoCandidatesReturnsNil()
        try testMissingActionStripRemovesBehaviorFromTheUrn()
        print("companion behavior: all assertions passed")
    }
}
