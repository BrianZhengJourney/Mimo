// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct StarterActionTests {
    static func testCatalogMatchesTheUserFacingStarterPack() {
        expect(StarterActionID.allCases == [.gaze, .sleep, .tennis, .wall],
               "the starter pack has exactly gaze, sleep, tennis, and wall")

        let gaze = StarterActionCatalog.definition(.gaze)
        expect(gaze.manifestActionName == "gaze", "gaze installs under the runtime gaze key")
        expect(gaze.finalFrameCount == 5,
               "cursor gaze needs neutral/up/right/down/left direction cells")
        expect(gaze.directions == [.neutral, .up, .right, .down, .left],
               "gaze directions have a stable runtime order")

        let sleep = StarterActionCatalog.definition(.sleep)
        expect(sleep.manifestActionName == "rest",
               "sleep remains compatible with the existing rest behavior key")
        expect(sleep.finalFrameCount == 9, "sleep is lie-down 3 + breathe 3 + rise 3")
        expect(sleep.segments.map(\.name) == ["lie-down", "breathing-loop", "rise"],
               "sleep exposes its three authored timing segments")

        let tennis = StarterActionCatalog.definition(.tennis)
        expect(tennis.finalFrameCount == 9, "tennis is prepare 3 + hit 3 + recover 3")
        expect(tennis.runtimeEffect == .tennisBall,
               "the generated strip omits the ball and the runtime owns it")

        let wall = StarterActionCatalog.definition(.wall)
        expect(wall.manifestActionName == "wall", "wall installs under the attached-state key")
        expect(wall.finalFrameCount == 6, "wall contains a 3-frame stand and 3-frame sit")
        expect(wall.segments.map(\.name) == ["wall-stand", "ledge-sit"],
               "wall exposes both user-requested edge poses")
    }

    static func testEveryDefinitionIsAValidCoherentFamilyPlan() {
        for id in StarterActionID.allCases {
            let definition = StarterActionCatalog.definition(id)
            expect(definition.batches.allSatisfy { $0.poses.count == 3 },
                   "\(id.rawValue) generates only coherent three-frame batches")
            expect(definition.batches.allSatisfy { (1...3).contains($0.keepCount) },
                   "\(id.rawValue) keeps a bounded number of frames from each batch")
            expect(definition.batches.reduce(0) { $0 + $1.keepCount }
                   == definition.finalFrameCount,
                   "\(id.rawValue) batch keep counts produce the declared final frame count")
            if id != .gaze {
                expect(definition.frameDurations.count == definition.finalFrameCount,
                       "\(id.rawValue) authors one hold per final frame")
            }
            let covered = definition.segments.flatMap { Array($0.frameRange) }
            if !definition.segments.isEmpty {
                expect(covered == Array(0..<definition.finalFrameCount),
                       "\(id.rawValue) segments cover every final frame once, in order")
            }
            expect(definition.estimatedProviderCalls == definition.batches.count,
                   "\(id.rawValue) discloses every paid coherent-family call")
        }
    }

    static func main() {
        testCatalogMatchesTheUserFacingStarterPack()
        testEveryDefinitionIsAValidCoherentFamilyPlan()
        print("starter action catalog tests passed")
    }
}
