// sources: companion_geometry.swift companion_physics.swift companion_sprite.swift companion_preview_catalog.swift
import Foundation

@main
struct CompanionPreviewCatalogTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func input(_ path: String) -> Data {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
            preconditionFailure("missing fixture: \(path)")
        }
        return data
    }

    static func testDefinitionsAreNamedAndUnique() {
        expect(CompanionPreviewCatalog.hatchPet.count == 11,
               "HatchPet exposes nine standard states, gaze, and neutral")
        expect(CompanionPreviewCatalog.independentFrames.count == 2,
               "both independent-frame experiments are exposed")
        expect(CompanionPreviewCatalog.hybridFrames.count == 6,
               "selected chained and historical hybrid experiments are exposed")
        let ids = CompanionPreviewCatalog.all.map(\.id)
        expect(Set(ids).count == ids.count, "preview ids must be unique")
        expect(CompanionPreviewCatalog.definition(id: "hatchpet.running")?.titleZh
               == "任务处理中",
               "HatchPet running keeps its task-processing meaning")
        let idle = CompanionPreviewCatalog.definition(id: "hatchpet.idle")
        expect(idle?.frameDurationsSeconds?.reduce(0, +) ?? 0 > 1.9,
               "ambient HatchPet previews keep the slower authored rhythm")
        expect(CompanionPreviewCatalog.definition(
            id: "hatchpet.running-right")?.framesPerSecond == 10,
               "large locomotion remains energetic")
        let hybridSleep = CompanionPreviewCatalog.definition(id: "experiment.hybrid.sleep-v1")
        expect(abs((hybridSleep?.frameDurationsSeconds?.reduce(0, +) ?? 0) - 5.3) < 0.001,
               "hybrid sleep preserves the authored slow-breath timing")
        expect(CompanionPreviewCatalog.definition(
            id: "experiment.hybrid.walk-v1")?.framesPerSecond == 10,
               "hybrid walk uses the authored 1.6-second gait cycle")
        let chainedSleep = CompanionPreviewCatalog.definition(
            id: "experiment.hybrid.sleep-v2")
        expect(chainedSleep?.asset == .horizontalStrip(frameCount: 9),
               "chained sleep exposes lie, breathe, and rise segments")
        expect(abs((chainedSleep?.frameDurationsSeconds?.reduce(0, +) ?? 0) - 4.73)
               < 0.001,
               "chained sleep preserves authored segment timing")
        expect(CompanionPreviewCatalog.definition(
            id: "experiment.hybrid.tennis-v1")?.asset
               == .horizontalStrip(frameCount: 9),
               "tennis exposes the complete nine-frame forehand")
    }

    static func testBundledHatchPetAtlasSlicesEveryPreview() {
        let data = input("mac/assets/preview/hatchpet/mimo-v2.webp")
        for definition in CompanionPreviewCatalog.hatchPet {
            guard case .hatchPetAtlas(let cells) = definition.asset else {
                preconditionFailure("\(definition.id) must use the v2 atlas")
            }
            let sprite = CompanionSprite.loadAtlas(
                data: data, columns: 8, rows: 11, cells: cells,
                fixedAnchorInCell: definition.fixedAnchorInCell)
            expect(sprite?.frameCount == cells.count,
                   "\(definition.id) slices \(cells.count) non-empty atlas cells")
            expect(sprite?.cellSize.width == 192 && sprite?.cellSize.height == 208,
                   "\(definition.id) preserves HatchPet cell geometry")
        }
    }

    static func testBundledIndependentFrameStripsLoad() {
        for definition in CompanionPreviewCatalog.independentFrames {
            guard case .horizontalStrip(let frameCount) = definition.asset else {
                preconditionFailure("\(definition.id) must use a horizontal strip")
            }
            let filename = definition.resourceName + "." + definition.resourceExtension
            let data = input("mac/assets/preview/experiments/\(filename)")
            let sprite = CompanionSprite.load(
                data: data, frameCount: frameCount, semantics: .actionPoses,
                fixedAnchorInCell: definition.fixedAnchorInCell)
            expect(sprite?.frameCount == 16, "\(definition.id) exposes all 16 frames")
            expect(sprite?.cellSize.width == 512 && sprite?.cellSize.height == 512,
                   "\(definition.id) preserves Mimo action-cell geometry")
        }
    }

    static func testBundledHybridFrameStripsLoad() {
        for definition in CompanionPreviewCatalog.hybridFrames {
            guard case .horizontalStrip(let frameCount) = definition.asset else {
                preconditionFailure("\(definition.id) must use a horizontal strip")
            }
            let filename = definition.resourceName + "." + definition.resourceExtension
            let data = input("mac/assets/preview/hybrid/\(filename)")
            let sprite = CompanionSprite.load(
                data: data, frameCount: frameCount, semantics: .actionPoses,
                fixedAnchorInCell: definition.fixedAnchorInCell)
            expect(sprite?.frameCount == frameCount,
                   "\(definition.id) exposes all \(frameCount) frames")
            expect(sprite?.cellSize.width == 512 && sprite?.cellSize.height == 512,
                   "\(definition.id) preserves Mimo action-cell geometry")
        }
    }

    static func main() {
        testDefinitionsAreNamedAndUnique()
        testBundledHatchPetAtlasSlicesEveryPreview()
        testBundledIndependentFrameStripsLoad()
        testBundledHybridFrameStripsLoad()
        print("companion preview catalog tests passed")
    }
}
