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
    case upperRight = "upper_right"
    case right
    case lowerRight = "lower_right"
    case down
    case lowerLeft = "lower_left"
    case left
    case upperLeft = "upper_left"
}

enum StarterActionRuntimeEffect: String, Codable, Equatable, Sendable {
    case none
    /// Tennis imagery deliberately contains no ball. A deterministic runtime
    /// layer keeps one ball on one authored trajectory without image drift.
    case tennisBall
}

struct StarterTennisBallSample: Equatable, Sendable {
    /// Position inside the companion layer, normalized from its bottom-left.
    /// Values may leave 0...1 so the ball can enter and exit beyond the sprite.
    let x: Double
    let y: Double
    let visible: Bool
}

/// The generated tennis strip deliberately contains no ball. Keeping its one
/// trajectory here makes the prop stable across frames, previews, pets, and
/// app launches instead of asking an image model to redraw a moving circle.
enum StarterTennisBallTrajectory {
    private static let nineFrameSamples: [StarterTennisBallSample] = [
        StarterTennisBallSample(x: 1.18, y: 0.80, visible: false),
        StarterTennisBallSample(x: 1.14, y: 0.76, visible: true),
        StarterTennisBallSample(x: 0.98, y: 0.65, visible: true),
        StarterTennisBallSample(x: 0.80, y: 0.56, visible: true),
        StarterTennisBallSample(x: 0.60, y: 0.50, visible: true),
        StarterTennisBallSample(x: 0.38, y: 0.57, visible: true),
        StarterTennisBallSample(x: 0.12, y: 0.67, visible: true),
        StarterTennisBallSample(x: -0.16, y: 0.82, visible: true),
        StarterTennisBallSample(x: -0.24, y: 0.88, visible: false),
    ]

    static func sample(frameIndex: Int, frameCount: Int)
        -> StarterTennisBallSample? {
        guard frameCount > 0 else { return nil }
        let wrapped = ((frameIndex % frameCount) + frameCount) % frameCount
        let canonical = min(
            nineFrameSamples.count - 1,
            Int(Double(wrapped) / Double(frameCount)
                * Double(nineFrameSamples.count)))
        return nineFrameSamples[canonical]
    }
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
    let poseContract: String
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
                poseContract: "Keep feet and lower body fixed. Eyes lead; head and neck "
                    + "may follow only enough to make all eight compass directions readable. Never "
                    + "rotate or redesign the whole sprite.",
                batches: [
                    StarterActionBatch(
                        poses: [
                            "look straight up",
                            "look toward upper screen-right",
                            "look toward screen-right",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "look toward lower screen-right",
                            "look straight down",
                            "look toward lower screen-left",
                        ],
                        keepCount: 3),
                    StarterActionBatch(
                        poses: [
                            "look toward screen-left",
                            "look toward upper screen-left",
                            "closure check: recreate straight-up gaze; discard this frame",
                        ],
                        keepCount: 2),
                ],
                frameDurations: [],
                segments: [],
                directions: [
                    .up, .upperRight, .right, .lowerRight,
                    .down, .lowerLeft, .left, .upperLeft,
                ],
                runtimeEffect: .none)

        case .sleep:
            return StarterActionDefinition(
                id: .sleep,
                manifestActionName: "rest",
                titleZh: "睡觉",
                titleEn: "Sleeping",
                motionClass: "segmented",
                poseContract: "Frames 1–3 settle from standing into one stable side-lying "
                    + "sleep construction. Frames 4–6 keep exactly that construction and "
                    + "only breathe. Frames 7–9 reverse the same path back to standing.",
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
                frameDurations: [0.42, 0.48, 0.72, 1.40, 1.20, 1.60, 0.40, 0.46, 0.66],
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
                poseContract: "Perform one readable forehand loop. Keep the same racket "
                    + "shape, strings, scale, and hand attachment throughout. Draw no "
                    + "tennis ball: Mimo supplies one deterministic runtime trajectory.",
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
                frameDurations: [0.42, 0.32, 0.24, 0.18, 0.16, 0.26, 0.34, 0.42, 0.62],
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
                poseContract: "The first family stands against an invisible screen wall; "
                    + "the second sits on an invisible edge with legs hanging. Keep the "
                    + "authored wall or ledge contact fixed and draw no scenery.",
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
                frameDurations: [0.95, 0.85, 1.25, 1.00, 0.85, 1.25],
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

struct StarterGazeSelection: Equatable, Sendable {
    let frameIndex: Int
    let mirrorHorizontally: Bool
}

/// Pure cursor-direction mapping shared by the native runtime and tests.
///
/// Production gaze uses eight explicitly authored compass directions. The
/// three- and five-frame experiments remain loadable, and legacy 11/16-frame
/// sweeps retain their old mirrored half-circle behavior.
enum StarterGazeMapper {
    static let neutralRadius = 24.0

    static func selection(dx: Double, dy: Double, frameCount: Int)
        -> StarterGazeSelection? {
        guard frameCount > 0, dx.isFinite, dy.isFinite else { return nil }
        let distance = hypot(dx, dy)
        guard distance.isFinite else { return nil }

        if distance <= neutralRadius {
            if frameCount == 8 { return nil }
            return StarterGazeSelection(frameIndex: 0, mirrorHorizontally: false)
        }
        if frameCount == 1 {
            return StarterGazeSelection(frameIndex: 0, mirrorHorizontally: false)
        }

        if frameCount == 8 {
            var clockwiseFromUp = atan2(dx, dy)
            if clockwiseFromUp < 0 { clockwiseFromUp += 2 * Double.pi }
            let octant = Int((clockwiseFromUp / (Double.pi / 4)).rounded()) % 8
            return StarterGazeSelection(
                frameIndex: octant, mirrorHorizontally: false)
        }

        if frameCount == 3 {
            return StarterGazeSelection(
                frameIndex: dx < 0 ? 1 : 2,
                mirrorHorizontally: false)
        }

        if frameCount == 5 {
            let index: Int
            if abs(dx) > abs(dy) {
                index = dx > 0 ? 2 : 4
            } else {
                index = dy > 0 ? 1 : 3
            }
            return StarterGazeSelection(frameIndex: index, mirrorHorizontally: false)
        }

        // Historical sheets author only the left half of a vertical sweep.
        // Reuse that pose on the right by mirroring the complete sprite.
        let sweepFrames = min(frameCount, 11)
        let normalizedY = max(-1.0, min(1.0, dy / max(distance, 1)))
        let angleFromUp = acos(normalizedY)
        let frame = Int((angleFromUp / Double.pi
                         * Double(max(0, sweepFrames - 1))).rounded())
        return StarterGazeSelection(
            frameIndex: min(max(frame, 0), frameCount - 1),
            mirrorHorizontally: dx > 12)
    }
}
