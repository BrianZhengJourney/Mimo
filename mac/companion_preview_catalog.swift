import CoreGraphics
import Foundation
import ImageIO

/// Bundled visual experiments that can be looped from the companion's Preview
/// menu without installing them into the active pet's behavior/action library.
struct CompanionPreviewDefinition: Equatable {
    enum Asset: Equatable {
        case hatchPetAtlas([CompanionAtlasCell])
        case horizontalStrip(frameCount: Int)
    }

    let id: String
    let titleZh: String
    let titleEn: String
    let resourceName: String
    let resourceExtension: String
    let resourceSubdirectory: String
    let asset: Asset
    let framesPerSecond: CGFloat
    let frameDurationsSeconds: [CGFloat]?
    let fixedAnchorInCell: CGPoint
}

struct CompanionPreviewAsset {
    let definition: CompanionPreviewDefinition
    let sprite: CompanionSprite

    var playbackSpec: CompanionActionPlaybackSpec {
        CompanionActionPlaybackSpec(
            framesPerSecond: definition.framesPerSecond,
            cycleDistanceInCellPixels: nil,
            frameDurationsSeconds: definition.frameDurationsSeconds)
    }
}

enum CompanionPreviewCatalog {
    static let hatchPet: [CompanionPreviewDefinition] = [
        hatchPetRow(
            "idle", "静息", "Idle", row: 0, fps: 3,
            durations: [0.50, 0.20, 0.20, 0.25, 0.25, 0.58]),
        hatchPetRow(
            "running-right", "向右移动", "Move Right", row: 1, fps: 10,
            frames: 8),
        hatchPetRow(
            "running-left", "向左移动", "Move Left", row: 2, fps: 10,
            frames: 8),
        hatchPetRow(
            "waving", "挥手", "Wave", row: 3, fps: 5,
            durations: [0.24, 0.18, 0.18, 0.52]),
        hatchPetRow(
            "jumping", "跳跃", "Jump", row: 4, fps: 10,
            durations: [0.10, 0.09, 0.12, 0.09, 0.18]),
        hatchPetRow(
            "failed", "失败 / 取消", "Failed / Cancelled", row: 5, fps: 4,
            durations: [0.20, 0.18, 0.18, 0.22, 0.26, 0.32, 0.42, 0.70]),
        hatchPetRow(
            "waiting", "等待用户", "Waiting for User", row: 6, fps: 3,
            durations: [0.32, 0.26, 0.26, 0.30, 0.32, 0.56]),
        hatchPetRow(
            "running", "任务处理中", "Working", row: 7, fps: 4,
            durations: [0.22, 0.20, 0.20, 0.22, 0.24, 0.44]),
        hatchPetRow(
            "review", "审阅结果", "Review Result", row: 8, fps: 3,
            durations: [0.30, 0.25, 0.25, 0.30, 0.35, 0.60]),
        CompanionPreviewDefinition(
            id: "hatchpet.look-16",
            titleZh: "16 方向注视",
            titleEn: "16-direction Look",
            resourceName: "mimo-v2",
            resourceExtension: "webp",
            resourceSubdirectory: "preview/hatchpet",
            asset: .hatchPetAtlas(
                (0..<8).map { CompanionAtlasCell(row: 9, column: $0) }
                + (0..<8).map { CompanionAtlasCell(row: 10, column: $0) }),
            framesPerSecond: 6,
            frameDurationsSeconds: nil,
            fixedAnchorInCell: CGPoint(x: 96, y: 203)),
        CompanionPreviewDefinition(
            id: "hatchpet.neutral",
            titleZh: "中性站姿",
            titleEn: "Neutral Pose",
            resourceName: "mimo-v2",
            resourceExtension: "webp",
            resourceSubdirectory: "preview/hatchpet",
            asset: .hatchPetAtlas([CompanionAtlasCell(row: 0, column: 6)]),
            framesPerSecond: 1,
            frameDurationsSeconds: nil,
            fixedAnchorInCell: CGPoint(x: 96, y: 203)),
    ]

    static let independentFrames: [CompanionPreviewDefinition] = [
        CompanionPreviewDefinition(
            id: "experiment.independent.sleep-16",
            titleZh: "睡觉 · 16 帧",
            titleEn: "Sleep · 16 Frames",
            resourceName: "independent-sleep-16",
            resourceExtension: "png",
            resourceSubdirectory: "preview/experiments",
            asset: .horizontalStrip(frameCount: 16),
            framesPerSecond: 4.5,
            frameDurationsSeconds: Array(repeating: 0.22, count: 16),
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.independent.walk-16",
            titleZh: "走路 · 16 帧",
            titleEn: "Walk · 16 Frames",
            resourceName: "independent-walk-16",
            resourceExtension: "png",
            resourceSubdirectory: "preview/experiments",
            asset: .horizontalStrip(frameCount: 16),
            framesPerSecond: 10,
            frameDurationsSeconds: nil,
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
    ]

    static let hybridFrames: [CompanionPreviewDefinition] = [
        CompanionPreviewDefinition(
            id: "experiment.hybrid.tennis-v1",
            titleZh: "打网球 · 9 帧（三针续接）",
            titleEn: "Tennis · 9 Frames (3-Frame Chaining)",
            resourceName: "tennis-hybrid-v1",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 9),
            framesPerSecond: 6,
            frameDurationsSeconds: [
                0.24, 0.18, 0.14, 0.10, 0.09, 0.16, 0.20, 0.24, 0.36,
            ],
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.hybrid.gaze-v1",
            titleZh: "注视 · 3 帧纯眼神",
            titleEn: "Gaze · 3-Frame Eye Motion",
            resourceName: "gaze-hybrid-v1",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 3),
            framesPerSecond: 1.5,
            frameDurationsSeconds: Array(repeating: 0.70, count: 3),
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.hybrid.sleep-v2",
            titleZh: "睡觉 · 躺下 / 呼吸 / 起身 v2",
            titleEn: "Sleep · Lie / Breathe / Rise v2",
            resourceName: "sleep-hybrid-v2",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 9),
            framesPerSecond: 1,
            frameDurationsSeconds: [
                0.26, 0.30, 0.48, 0.90, 0.75, 1.10, 0.24, 0.28, 0.42,
            ],
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.hybrid.wall-stand-v1",
            titleZh: "靠墙站 · 3 帧慢呼吸",
            titleEn: "Wall Stand · 3-Frame Slow Breath",
            resourceName: "wall-stand-hybrid-v1",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 3),
            framesPerSecond: 1,
            frameDurationsSeconds: [0.70, 0.55, 0.95],
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.hybrid.sleep-v1",
            titleZh: "睡觉 · 6 帧慢呼吸 v1",
            titleEn: "Sleep · 6-frame Slow Breath v1",
            resourceName: "sleep-hybrid-v1",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 6),
            framesPerSecond: 1,
            frameDurationsSeconds: [0.90, 0.75, 0.90, 0.75, 0.90, 1.10],
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
        CompanionPreviewDefinition(
            id: "experiment.hybrid.walk-v1",
            titleZh: "走路 · 16 帧 v1",
            titleEn: "Walk · 16 Frames v1",
            resourceName: "walk-hybrid-v1",
            resourceExtension: "png",
            resourceSubdirectory: "preview/hybrid",
            asset: .horizontalStrip(frameCount: 16),
            framesPerSecond: 10,
            frameDurationsSeconds: nil,
            fixedAnchorInCell: CGPoint(x: 256, y: 502)),
    ]

    static var all: [CompanionPreviewDefinition] {
        hatchPet + hybridFrames + independentFrames
    }

    static func definition(id: String) -> CompanionPreviewDefinition? {
        all.first { $0.id == id }
    }

    static func loadHatchPet(bundle: Bundle = .main) -> [CompanionPreviewAsset] {
        guard let url = bundle.url(
            forResource: "mimo-v2", withExtension: "webp",
            subdirectory: "preview/hatchpet"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return hatchPet.compactMap { definition in
            guard case .hatchPetAtlas(let cells) = definition.asset,
                  let sprite = CompanionSprite.loadAtlas(
                    sheet: sheet, columns: 8, rows: 11, cells: cells,
                    semantics: .actionPoses,
                    fixedAnchorInCell: definition.fixedAnchorInCell) else { return nil }
            return CompanionPreviewAsset(definition: definition, sprite: sprite)
        }
    }

    static func loadIndependentFrames(bundle: Bundle = .main) -> [CompanionPreviewAsset] {
        independentFrames.compactMap { load($0, bundle: bundle) }
    }

    static func loadHybridFrames(bundle: Bundle = .main) -> [CompanionPreviewAsset] {
        hybridFrames.compactMap { load($0, bundle: bundle) }
    }

    static func load(_ definition: CompanionPreviewDefinition,
                     bundle: Bundle = .main) -> CompanionPreviewAsset? {
        guard let url = bundle.url(
            forResource: definition.resourceName,
            withExtension: definition.resourceExtension,
            subdirectory: definition.resourceSubdirectory),
              let data = try? Data(contentsOf: url) else { return nil }
        let sprite: CompanionSprite?
        switch definition.asset {
        case .hatchPetAtlas(let cells):
            sprite = CompanionSprite.loadAtlas(
                data: data, columns: 8, rows: 11, cells: cells,
                semantics: .actionPoses,
                fixedAnchorInCell: definition.fixedAnchorInCell)
        case .horizontalStrip(let frameCount):
            sprite = CompanionSprite.load(
                data: data, frameCount: frameCount, semantics: .actionPoses,
                fixedAnchorInCell: definition.fixedAnchorInCell)
        }
        guard let sprite else { return nil }
        return CompanionPreviewAsset(definition: definition, sprite: sprite)
    }

    private static func hatchPetRow(
        _ id: String, _ titleZh: String, _ titleEn: String,
        row: Int, fps: CGFloat, frames: Int? = nil,
        durations: [CGFloat]? = nil
    ) -> CompanionPreviewDefinition {
        let frameCount = frames ?? durations?.count ?? 0
        precondition(frameCount > 0)
        precondition(durations == nil || durations?.count == frameCount)
        return CompanionPreviewDefinition(
            id: "hatchpet.\(id)",
            titleZh: titleZh,
            titleEn: titleEn,
            resourceName: "mimo-v2",
            resourceExtension: "webp",
            resourceSubdirectory: "preview/hatchpet",
            asset: .hatchPetAtlas(
                (0..<frameCount).map { CompanionAtlasCell(row: row, column: $0) }),
            framesPerSecond: fps,
            frameDurationsSeconds: durations,
            fixedAnchorInCell: CGPoint(x: 96, y: 203))
    }
}
