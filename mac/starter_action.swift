import Foundation

/// The first motion pack a DIY familiar can grow after its canonical master is
/// accepted. Keep this list product-sized: optional personality actions belong
/// in later packs and must not block adoption.
enum StarterActionID: String, Codable, CaseIterable, Sendable {
    case gaze
    case sleep
    case tennis
    case wall
}

enum StarterActionDirection: String, Codable, Equatable, Sendable {
    case neutral
    case up
    case right
    case down
    case left
}

enum StarterActionRuntimeEffect: String, Codable, Equatable, Sendable {
    case none
    /// Tennis imagery deliberately contains no ball. A deterministic runtime
    /// layer keeps one ball on one authored trajectory without image drift.
    case tennisBall
}

struct StarterActionBatch: Equatable, Sendable {
    /// Every provider call draws exactly one coherent three-frame family.
    let poses: [String]
    /// Closure-check frames are generated beside their family but discarded.
    let keepCount: Int
}

struct StarterActionSegment: Equatable, Sendable {
    let name: String
    let frameRange: Range<Int>
    let loops: Bool
}

struct StarterActionDefinition: Equatable, Sendable {
    let id: StarterActionID
    /// Key written to CustomPetManifest and consumed by CompanionRuntime.
    let manifestActionName: String
    let titleZh: String
    let titleEn: String
    let motionClass: String
    let batches: [StarterActionBatch]
    let frameDurations: [Double]
    let segments: [StarterActionSegment]
    let directions: [StarterActionDirection]
    let runtimeEffect: StarterActionRuntimeEffect

    var finalFrameCount: Int {
        batches.reduce(0) { $0 + $1.keepCount }
    }

    /// One provider request per coherent family. This is surfaced before a
    /// user starts generation; chained batches must never become hidden spend.
    var estimatedProviderCalls: Int { batches.count }

    /// Constant-FPS fallback for contact-sheet preview only. Runtime behavior
    /// uses authored holds, and gaze maps direction rather than playing a loop.
    var previewFramesPerSecond: Double {
        let duration = frameDurations.reduce(0, +)
        guard duration > 0 else { return 2 }
        return Double(finalFrameCount) / duration
    }
}

enum StarterActionCatalog {
    static func definition(_ id: StarterActionID) -> StarterActionDefinition {
        switch id {
        case .gaze:
            return StarterActionDefinition(
                id: .gaze,
                manifestActionName: "gaze",
                titleZh: "跟随光标",
                titleEn: "Follow the cursor",
                motionClass: "directional",
                batches: [
                    StarterActionBatch(
                        poses: [
                            "neutral gaze",
                            "look up",
                            "look toward screen-right",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "look down",
                            "look toward screen-left",
                            "closure check: recreate neutral gaze; discard this frame",
                        ],
                        keepCount: 2),
                ],
                frameDurations: [],
                segments: [],
                directions: [.neutral, .up, .right, .down, .left],
                runtimeEffect: .none)

        case .sleep:
            return StarterActionDefinition(
                id: .sleep,
                manifestActionName: "rest",
                titleZh: "睡觉",
                titleEn: "Sleeping",
                motionClass: "segmented",
                batches: [
                    StarterActionBatch(
                        poses: [
                            "standing, preparing to settle",
                            "body lowers with hands reaching support",
                            "side-lying sleep pose becomes fully established",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "same sleep pose at settled exhale",
                            "same sleep pose at slow inhale crest",
                            "same sleep pose returning to settled exhale",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "sleep pose wakes and torso rises",
                            "supported crouch transitioning upward",
                            "stable canonical standing pose",
                        ],
                        keepCount: 3),
                ],
                frameDurations: [0.26, 0.30, 0.48, 0.90, 0.75, 1.10, 0.24, 0.28, 0.42],
                segments: [
                    StarterActionSegment(name: "lie-down", frameRange: 0..<3, loops: false),
                    StarterActionSegment(name: "breathing-loop", frameRange: 3..<6, loops: true),
                    StarterActionSegment(name: "rise", frameRange: 6..<9, loops: false),
                ],
                directions: [],
                runtimeEffect: .none)

        case .tennis:
            return StarterActionDefinition(
                id: .tennis,
                manifestActionName: "tennis",
                titleZh: "打网球",
                titleEn: "Play tennis",
                motionClass: "gesture",
                batches: [
                    StarterActionBatch(
                        poses: [
                            "athletic ready stance holding the racket",
                            "weight shift and racket preparation",
                            "forehand backswing reaches its useful extreme",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "forward acceleration begins",
                            "clean forehand contact pose; no ball is drawn",
                            "follow-through crosses the body",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "follow-through settles",
                            "feet and racket recover toward ready stance",
                            "original athletic ready stance, closing the loop",
                        ],
                        keepCount: 3),
                ],
                frameDurations: [0.24, 0.18, 0.14, 0.10, 0.09, 0.16, 0.20, 0.24, 0.36],
                segments: [
                    StarterActionSegment(name: "forehand-loop", frameRange: 0..<9, loops: true),
                ],
                directions: [],
                runtimeEffect: .tennisBall)

        case .wall:
            return StarterActionDefinition(
                id: .wall,
                manifestActionName: "wall",
                titleZh: "墙边站着 / 坐着",
                titleEn: "Stand / sit by the edge",
                motionClass: "ambient",
                batches: [
                    StarterActionBatch(
                        poses: [
                            "relaxed wall-standing pose at settled exhale",
                            "same wall contact with a small inhale and weight shift",
                            "same relaxed wall-standing pose, closing the seam",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "sitting on an invisible screen-edge ledge, legs hanging",
                            "same ledge contact with one gentle alternating leg swing",
                            "same settled ledge-sit pose, closing the seam",
                        ],
                        keepCount: 3),
                ],
                frameDurations: [0.70, 0.55, 0.95, 0.75, 0.55, 0.95],
                segments: [
                    StarterActionSegment(name: "wall-stand", frameRange: 0..<3, loops: true),
                    StarterActionSegment(name: "ledge-sit", frameRange: 3..<6, loops: true),
                ],
                directions: [],
                runtimeEffect: .none)
        }
    }

    static var all: [StarterActionDefinition] {
        StarterActionID.allCases.map(definition)
    }

    static func definition(manifestActionName: String) -> StarterActionDefinition? {
        all.first { $0.manifestActionName == manifestActionName }
    }
}
