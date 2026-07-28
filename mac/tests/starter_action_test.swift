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

    static func testGazeMappingFollowsTheCursorAcrossSupportedContracts() {
        expect(StarterGazeMapper.selection(dx: 0, dy: 200, frameCount: 5)?.frameIndex == 1,
               "five-direction gaze looks up")
        expect(StarterGazeMapper.selection(dx: 200, dy: 0, frameCount: 5)?.frameIndex == 2,
               "five-direction gaze looks right")
        expect(StarterGazeMapper.selection(dx: 0, dy: -200, frameCount: 5)?.frameIndex == 3,
               "five-direction gaze looks down")
        expect(StarterGazeMapper.selection(dx: -200, dy: 0, frameCount: 5)?.frameIndex == 4,
               "five-direction gaze looks left")
        expect(StarterGazeMapper.selection(dx: 5, dy: 4, frameCount: 5)?.frameIndex == 0,
               "a cursor at eye position selects neutral")

        let legacyLeft = StarterGazeMapper.selection(dx: -160, dy: 0, frameCount: 16)
        let legacyRight = StarterGazeMapper.selection(dx: 160, dy: 0, frameCount: 16)
        expect(legacyLeft?.frameIndex == legacyRight?.frameIndex,
               "legacy sweep uses the same authored pose on both sides")
        expect(legacyLeft?.mirrorHorizontally == false
               && legacyRight?.mirrorHorizontally == true,
               "legacy sweep mirrors the authored left side toward the cursor")

        expect(StarterGazeMapper.selection(dx: -100, dy: 0, frameCount: 3)?.frameIndex == 1,
               "historical three-frame gaze keeps neutral/left/right order")
        expect(StarterGazeMapper.selection(dx: 100, dy: 0, frameCount: 3)?.frameIndex == 2,
               "historical three-frame gaze can still follow horizontally")
    }

    static func testDefaultBehaviorPackUsesOnlyStarterContractFrames() throws {
        let data = try Data(contentsOf: URL(
            fileURLWithPath: "mac/assets/behavior/default.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let actions = (root["actions"] as! [[String: Any]]).reduce(into: [String: [String: Any]]()) {
            $0[$1["name"] as! String] = $1
        }

        func poses(_ action: String) -> [[String: Any]] {
            let animations = actions[action]?["animations"] as? [[String: Any]] ?? []
            return animations.flatMap { $0["poses"] as? [[String: Any]] ?? [] }
        }
        func frames(_ action: String, strip: String) -> [Int] {
            poses(action).compactMap {
                $0["strip"] as? String == strip ? $0["frame"] as? Int : nil
            }
        }

        let restFrames = ["RestSettle", "RestSleep", "RestRise"]
            .flatMap { frames($0, strip: "rest") }
        expect(restFrames == Array(0...8),
               "sleep behavior plays the nine authored frames once in phase order")

        let tennisFrames = frames("PlayTennis", strip: "tennis")
        expect(tennisFrames == Array(0...8), "tennis plays the complete forehand family")

        expect(frames("ClingWall", strip: "wall") == Array(0...2),
               "wall stand uses the first coherent family")
        expect(frames("SitAtWall", strip: "wall") == Array(3...5),
               "wall sit uses the second coherent family")
    }

    static func main() throws {
        testCatalogMatchesTheUserFacingStarterPack()
        testEveryDefinitionIsAValidCoherentFamilyPlan()
        testGazeMappingFollowsTheCursorAcrossSupportedContracts()
        try testDefaultBehaviorPackUsesOnlyStarterContractFrames()
        print("starter action catalog tests passed")
    }
}
