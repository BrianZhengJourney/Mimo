import CoreGraphics
import Foundation

// Behavior packs: what a companion does when nobody is touching it.
//
// The mechanism is Shimeji's, because it is the part that earns its keep — a
// weighted urn filtered by conditions, plus per-behaviour follow-up lists. No
// planner, no behaviour tree. What produces the sense of intent is the mix of
// two chain modes and the fact that gating is subtractive: a behaviour whose
// condition fails is simply not in the urn, so a grounded companion and an
// airborne one draw from different pools without any corrective logic.
//
// See docs/companion/01-shimeji-research.md §1.4 for why this feels good, and
// §1.9 for what is deliberately not copied.

// MARK: - Actions

enum CompanionActionKind: String, Codable {
    /// Hold position until the duration elapses.
    case stay
    /// Walk toward a target x on the current surface.
    case move
    /// Play the animation through once.
    case animate
    /// Run children in order.
    case sequence
    /// Run the first child whose condition passes.
    case select
    /// Hand off to native behaviour (fall, dragged, thrown).
    case embedded
}

/// A single authored pose: which frame, how long, and how fast to travel.
///
/// Durations are seconds and velocity is px/second, not ticks and per-tick
/// offsets. Shimeji's units bake its 25fps into every pack, so its frame rate
/// cannot be raised without changing how far everything moves.
struct CompanionPose {
    let frame: Int
    let hold: Double
    let velocity: CGVector
}

struct CompanionAnimation {
    /// Optional gate; the first animation whose condition passes is used, which
    /// is how one action becomes pose-reactive.
    let condition: CompanionExpression?
    let poses: [CompanionPose]

    var totalDuration: Double { poses.reduce(0) { $0 + $1.hold } }

    /// Pose at `time` seconds, looping. Mirrors Shimeji's `time % duration`
    /// lookup: there is no separate animation player.
    func pose(at time: Double) -> CompanionPose? {
        guard !poses.isEmpty else { return nil }
        let total = totalDuration
        guard total > 0 else { return poses.first }
        var remaining = time.truncatingRemainder(dividingBy: total)
        for pose in poses {
            remaining -= pose.hold
            if remaining < 0 { return pose }
        }
        return poses.last
    }
}

struct CompanionAction {
    let name: String
    let kind: CompanionActionKind
    /// State the companion must be in for this action to be legal.
    let requires: CompanionStateRequirement
    let duration: CompanionExpression?
    let targetX: CompanionExpression?
    let animations: [CompanionAnimation]
    let children: [String]
    /// For `.embedded`, which native behaviour to hand off to.
    let implementation: String?

    /// First animation whose condition passes.
    func animation(for source: CompanionVariableSource) -> CompanionAnimation? {
        for animation in animations {
            guard let condition = animation.condition else { return animation }
            if condition.evaluateBool(source) { return animation }
        }
        return nil
    }
}

/// Precondition on the motion state.
///
/// Shimeji has no equivalent: it discovers illegality at runtime by throwing
/// LostGroundException out of a tick. Declaring it lets the loader reject a
/// chain that can never fire, and lets the selector filter rather than correct.
enum CompanionStateRequirement: Equatable {
    case any
    case grounded
    case airborne
    case held

    init(_ raw: String?) {
        switch raw {
        case "grounded": self = .grounded
        case "airborne": self = .airborne
        case "held": self = .held
        default: self = .any
        }
    }

    func isSatisfied(by state: String) -> Bool {
        switch self {
        case .any: return true
        case .grounded: return state == "grounded"
        case .airborne: return state == "airborne"
        case .held: return state == "held"
        }
    }
}

// MARK: - Behaviours

struct CompanionBehaviorReference {
    let name: String
    let frequency: Int
    let condition: CompanionExpression?
}

struct CompanionBehavior {
    let name: String
    /// Relative weight in the urn.
    ///
    /// Zero does not mean disabled — it means "reachable only by explicit
    /// reference". That is how a behaviour becomes a chain destination without
    /// ever being drawn at random.
    let frequency: Int
    let condition: CompanionExpression?
    let actionName: String
    /// Whether the global pool competes alongside this behaviour's own
    /// follow-ups. True unions the two (a nudge); false excludes the pool
    /// entirely (a commitment). Mixing the modes is what reads as intent.
    let nextIsAdditive: Bool
    let next: [CompanionBehaviorReference]

    func isEffective(for source: CompanionVariableSource) -> Bool {
        guard let condition else { return true }
        return condition.evaluateBool(source)
    }
}

// MARK: - Pack

struct CompanionBehaviorPack {
    let schemaVersion: Int
    let actions: [String: CompanionAction]
    let behaviors: [String: CompanionBehavior]
    /// Insertion order, so selection is deterministic given the same random draw.
    let behaviorOrder: [String]

    func action(named name: String) -> CompanionAction? { actions[name] }
    func behavior(named name: String) -> CompanionBehavior? { behaviors[name] }
}

enum CompanionPackError: Error, CustomStringConvertible {
    case notAnObject
    case unsupportedSchema(Int)
    case missingField(String, in: String)
    case badExpression(String, in: String, underlying: String)
    case unknownAction(String, referencedBy: String)
    case unknownBehavior(String, referencedBy: String)
    case unreachableChain(String, from: String, reason: String)
    case noReachableBehavior

    var description: String {
        switch self {
        case .notAnObject: return "behavior pack must be a JSON object"
        case .unsupportedSchema(let version): return "unsupported pack schemaVersion \(version)"
        case .missingField(let field, let owner): return "'\(owner)' is missing '\(field)'"
        case .badExpression(let source, let owner, let underlying):
            return "'\(owner)': bad expression '\(source)' — \(underlying)"
        case .unknownAction(let name, let owner):
            return "behavior '\(owner)' refers to unknown action '\(name)'"
        case .unknownBehavior(let name, let owner):
            return "'\(owner)' chains to unknown behavior '\(name)'"
        case .unreachableChain(let name, let owner, let reason):
            return "'\(owner)' chains to '\(name)' which can never run: \(reason)"
        case .noReachableBehavior:
            return "no behavior can ever be selected"
        }
    }
}

// MARK: - Selection

/// Picks the next behaviour, exactly as Shimeji does.
///
/// The whole algorithm: collect candidates whose conditions pass, sum their
/// weights, draw. The global pool participates only when there is no previous
/// behaviour or when the previous one declared its chain additive.
struct CompanionBehaviorSelector {
    let pack: CompanionBehaviorPack

    func selectNext(after previous: CompanionBehavior?,
                    source: CompanionVariableSource,
                    random: () -> Double = { Double.random(in: 0..<1) }) -> CompanionBehavior? {
        var candidates: [(CompanionBehavior, Int)] = []

        if previous == nil || previous!.nextIsAdditive {
            for name in pack.behaviorOrder {
                guard let behavior = pack.behaviors[name], behavior.frequency > 0,
                      behavior.isEffective(for: source) else { continue }
                candidates.append((behavior, behavior.frequency))
            }
        }

        if let previous {
            for reference in previous.next {
                guard let behavior = pack.behaviors[reference.name], reference.frequency > 0
                else { continue }
                if let condition = reference.condition, !condition.evaluateBool(source) { continue }
                guard behavior.isEffective(for: source) else { continue }
                candidates.append((behavior, reference.frequency))
            }
        }

        let total = candidates.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }

        var roll = random() * Double(total)
        for (behavior, weight) in candidates {
            roll -= Double(weight)
            if roll < 0 { return behavior }
        }
        return candidates.last?.0
    }
}

// MARK: - Loading

extension CompanionBehaviorPack {
    static let supportedSchemaVersion = 1

    static func load(data: Data,
                     schema: CompanionVariableSchema = .current) throws -> CompanionBehaviorPack {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompanionPackError.notAnObject
        }
        return try load(root, schema: schema)
    }

    static func load(_ root: [String: Any],
                     schema: CompanionVariableSchema = .current) throws -> CompanionBehaviorPack {
        let version = (root["schemaVersion"] as? NSNumber)?.intValue ?? 1
        guard version == supportedSchemaVersion else {
            throw CompanionPackError.unsupportedSchema(version)
        }

        // JSON has one number type; Swift's bridge does not. A pack author
        // writing `"hold": 1` rather than `1.0` produces an Int, and a plain
        // `as? Double` silently drops it to the default — so every number goes
        // through NSNumber.
        func double(_ raw: Any?, default fallback: Double) -> Double {
            (raw as? NSNumber)?.doubleValue ?? fallback
        }
        func integer(_ raw: Any?, default fallback: Int) -> Int {
            (raw as? NSNumber)?.intValue ?? fallback
        }
        func vector(_ raw: Any?) -> CGVector {
            guard let values = raw as? [Any] else { return .zero }
            let numbers = values.compactMap { ($0 as? NSNumber)?.doubleValue }
            return CGVector(dx: numbers.count > 0 ? numbers[0] : 0,
                            dy: numbers.count > 1 ? numbers[1] : 0)
        }

        func compile(_ raw: Any?, owner: String) throws -> CompanionExpression? {
            guard let raw else { return nil }
            let source: String
            if let text = raw as? String { source = text }
            else if let value = raw as? NSNumber { source = value.stringValue }
            else { return nil }
            do { return try CompanionExpression.compile(source, schema: schema) }
            catch {
                throw CompanionPackError.badExpression(source, in: owner,
                                                       underlying: "\(error)")
            }
        }

        // ── actions ──
        var actions: [String: CompanionAction] = [:]
        for entry in root["actions"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else {
                throw CompanionPackError.missingField("name", in: "action")
            }
            let kind = CompanionActionKind(rawValue: entry["type"] as? String ?? "stay") ?? .stay

            var animations: [CompanionAnimation] = []
            for block in entry["animations"] as? [[String: Any]] ?? [] {
                var poses: [CompanionPose] = []
                for pose in block["poses"] as? [[String: Any]] ?? [] {
                    poses.append(CompanionPose(
                        frame: integer(pose["frame"], default: 0),
                        hold: double(pose["hold"], default: 0.2),
                        velocity: vector(pose["velocity"])))
                }
                animations.append(CompanionAnimation(
                    condition: try compile(block["when"], owner: "action '\(name)'"),
                    poses: poses))
            }

            actions[name] = CompanionAction(
                name: name,
                kind: kind,
                requires: CompanionStateRequirement(entry["requires"] as? String),
                duration: try compile(entry["duration"], owner: "action '\(name)'"),
                targetX: try compile(entry["targetX"], owner: "action '\(name)'"),
                animations: animations,
                children: entry["children"] as? [String] ?? [],
                implementation: entry["impl"] as? String)
        }

        // ── behaviours ──
        var behaviors: [String: CompanionBehavior] = [:]
        var order: [String] = []
        for entry in root["behaviors"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else {
                throw CompanionPackError.missingField("name", in: "behavior")
            }
            let nextBlock = entry["next"] as? [String: Any]
            var references: [CompanionBehaviorReference] = []
            for reference in nextBlock?["refs"] as? [[String: Any]] ?? [] {
                guard let target = reference["name"] as? String else {
                    throw CompanionPackError.missingField("name", in: "next of '\(name)'")
                }
                references.append(CompanionBehaviorReference(
                    name: target,
                    frequency: integer(reference["frequency"], default: 0),
                    condition: try compile(reference["when"], owner: "next of '\(name)'")))
            }

            behaviors[name] = CompanionBehavior(
                name: name,
                frequency: integer(entry["frequency"], default: 0),
                condition: try compile(entry["when"], owner: "behavior '\(name)'"),
                actionName: entry["action"] as? String ?? name,
                nextIsAdditive: nextBlock?["additive"] as? Bool ?? true,
                next: references)
            order.append(name)
        }

        let pack = CompanionBehaviorPack(schemaVersion: version, actions: actions,
                                         behaviors: behaviors, behaviorOrder: order)
        try pack.validate()
        return pack
    }

    /// Load-time graph checks.
    ///
    /// Shimeji validates none of this; a chain to a nonexistent behaviour, or
    /// one whose precondition can never hold at that point, simply produces a
    /// mascot that drops out of the sky with no diagnostic. Catching it here
    /// means the pack author sees the name of what is wrong.
    func validate() throws {
        for name in behaviorOrder {
            guard let behavior = behaviors[name] else { continue }
            guard let action = actions[behavior.actionName] else {
                throw CompanionPackError.unknownAction(behavior.actionName, referencedBy: name)
            }

            for child in action.children where actions[child] == nil {
                throw CompanionPackError.unknownAction(child, referencedBy: "action '\(action.name)'")
            }

            for reference in behavior.next {
                guard let target = behaviors[reference.name] else {
                    throw CompanionPackError.unknownBehavior(reference.name, referencedBy: name)
                }
                guard let targetAction = actions[target.actionName] else {
                    throw CompanionPackError.unknownAction(target.actionName,
                                                           referencedBy: reference.name)
                }
                // An action that ends grounded cannot chain to one that demands
                // airborne, and vice versa. This is the check that turns
                // Shimeji's runtime surprise into a load error.
                if action.requires == .grounded && targetAction.requires == .airborne {
                    throw CompanionPackError.unreachableChain(
                        reference.name, from: name,
                        reason: "'\(action.name)' leaves the companion grounded but "
                              + "'\(targetAction.name)' requires airborne")
                }
                if action.requires == .held && targetAction.requires == .held {
                    throw CompanionPackError.unreachableChain(
                        reference.name, from: name,
                        reason: "a held action cannot chain to another held action; "
                              + "release is driven by the cursor, not the pack")
                }
            }
        }

        let selectable = behaviorOrder.compactMap { behaviors[$0] }.filter { $0.frequency > 0 }
        guard !selectable.isEmpty else { throw CompanionPackError.noReachableBehavior }
    }
}
