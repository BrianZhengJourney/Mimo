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
               "the starter pack stays focused on the four accepted actions")

        let gaze = StarterActionCatalog.definition(.gaze)
        expect(gaze.manifestActionName == "gaze", "gaze installs under the runtime gaze key")
        expect(gaze.finalFrameCount == 8,
               "cursor gaze authors the eight compass directions")
        expect(gaze.directions == [
            .up, .upperRight, .right, .lowerRight,
            .down, .lowerLeft, .left, .upperLeft,
        ], "gaze directions have a stable clockwise runtime order")

        let sleep = StarterActionCatalog.definition(.sleep)
        expect(sleep.manifestActionName == "rest",
               "sleep remains compatible with the existing rest behavior key")
        expect(sleep.finalFrameCount == 6, "sleep is lie-down 3 + breathe 3")
        expect(sleep.estimatedProviderCalls == 2,
               "sleep no longer spends a third call drawing an unwanted rise")
        expect(sleep.segments.map(\.name) == ["lie-down", "breathing-loop"],
               "sleep settles once and then exposes only its breathing loop")
        expect(sleep.contractRevision == 3,
               "the sleep safe-zone contract can migrate clipped durable jobs")
        let sleepPoses = sleep.batches.flatMap(\.poses).joined(separator: " ")
        expect(sleepPoses.contains("head resting sideways on folded hands")
               && sleepPoses.contains("tiny relaxed pout"),
               "sleep keeps the cute prone head-on-hands construction")
        expect(!sleepPoses.contains("rises") && !sleepPoses.contains("standing pose"),
               "sleep never authors a wake-up or standing phase")

        let tennis = StarterActionCatalog.definition(.tennis)
        expect(tennis.finalFrameCount == 9, "tennis is prepare 3 + hit 3 + recover 3")
        expect(tennis.runtimeEffect == .tennisBall,
               "the generated strip omits the ball and the runtime owns it")

        let wall = StarterActionCatalog.definition(.wall)
        expect(wall.manifestActionName == "wall", "wall installs under the attached-state key")
        expect(wall.finalFrameCount == 6, "wall contains a 3-frame stand and 3-frame sit")
        expect(wall.segments.map(\.name) == ["wall-stand", "ledge-sit"],
               "wall exposes both user-requested edge poses")

        expect(StarterActionCatalog.all.reduce(0) { $0 + $1.finalFrameCount } == 29,
               "the four accepted actions author 29 retained frames")
        expect(StarterActionCatalog.all.reduce(0) { $0 + $1.estimatedProviderCalls } == 10,
               "the four accepted actions disclose 10 provider calls")
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
            expect((1.0...60.0).contains(definition.previewFramesPerSecond),
                   "\(id.rawValue) preview FPS must satisfy action metadata validation")
        }
    }

    static func testGazeMappingFollowsTheCursorAcrossSupportedContracts() {
        expect(StarterGazeMapper.selection(dx: 0, dy: 200, frameCount: 8)?.frameIndex == 0,
               "eight-direction gaze looks straight up")
        expect(StarterGazeMapper.selection(dx: 200, dy: 200, frameCount: 8)?.frameIndex == 1,
               "eight-direction gaze looks upper-right")
        expect(StarterGazeMapper.selection(dx: 200, dy: 0, frameCount: 8)?.frameIndex == 2,
               "eight-direction gaze looks right")
        expect(StarterGazeMapper.selection(dx: 200, dy: -200, frameCount: 8)?.frameIndex == 3,
               "eight-direction gaze looks lower-right")
        expect(StarterGazeMapper.selection(dx: 0, dy: -200, frameCount: 8)?.frameIndex == 4,
               "eight-direction gaze looks straight down")
        expect(StarterGazeMapper.selection(dx: -200, dy: -200, frameCount: 8)?.frameIndex == 5,
               "eight-direction gaze looks lower-left")
        expect(StarterGazeMapper.selection(dx: -200, dy: 0, frameCount: 8)?.frameIndex == 6,
               "eight-direction gaze looks left")
        expect(StarterGazeMapper.selection(dx: -200, dy: 200, frameCount: 8)?.frameIndex == 7,
               "eight-direction gaze looks upper-left")
        expect(StarterGazeMapper.selection(dx: 5, dy: 4, frameCount: 8) == nil,
               "the base sprite remains visible while the cursor is near the eyes")

        expect(StarterGazeMapper.selection(dx: 0, dy: 200, frameCount: 5)?.frameIndex == 1,
               "legacy five-direction gaze still looks up")
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

    static func testGazeWaitsForASettledCursorAndFocusDisablesIt() {
        var follow = CompanionGazeFollowProcedure()
        for _ in 0..<18 {
            let frame = follow.update(
                dt: 0.02, dx: 180, dy: 0, cursorSpeed: 12,
                frameCount: 8, enabled: true)
            expect(frame == nil, "a nearby cursor must linger before the familiar glances")
        }
        let settled = follow.update(
            dt: 0.20, dx: 180, dy: 0, cursorSpeed: 12,
            frameCount: 8, enabled: true)
        expect(settled == 2, "a cursor held nearby long enough earns one calm glance")

        let frozen = follow.update(
            dt: 0.30, dx: -180, dy: 0, cursorSpeed: 800,
            frameCount: 8, enabled: true)
        expect(frozen == 2, "fast cursor motion freezes the last readable glance")
        expect(follow.update(
            dt: 0.40, dx: -180, dy: 0, cursorSpeed: 0,
            frameCount: 8, enabled: false) == nil,
               "Focus mode clears gaze instead of competing for attention")
    }

    static func testTennisBallOwnsOneDeterministicNineFrameTrajectory() {
        let samples = (0..<9).map {
            StarterTennisBallTrajectory.sample(frameIndex: $0, frameCount: 9)!
        }
        expect(samples.first?.visible == false && samples.last?.visible == false,
               "the runtime ball enters after preparation and leaves before the loop seam")
        let visible = samples.filter(\.visible)
        expect(visible.count == 7,
               "exactly one runtime ball is visible across the seven swing frames")
        expect(zip(visible, visible.dropFirst()).allSatisfy { $0.x > $1.x },
               "the ball follows one authored horizontal direction through contact")
        expect(samples[4].y == visible.map(\.y).min(),
               "the contact frame is the low point of the authored arc")
        expect(StarterTennisBallTrajectory.sample(frameIndex: 9, frameCount: 9)
               == samples[0],
               "the deterministic ball closes exactly at the nine-frame seam")
        expect(StarterTennisBallTrajectory.sample(frameIndex: 0, frameCount: 0) == nil,
               "an invalid strip cannot display a stray ball")
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

        let restFrames = ["RestSettle", "RestSleep"]
            .flatMap { frames($0, strip: "rest") }
        expect(restFrames == Array(0...5),
               "sleep plays the settle once and keeps only the breathing family")
        expect(actions["RestRise"] == nil,
               "the shipped action pack contains no automatic sleep rise")
        expect(actions["RestSleep"]?["duration"] == nil,
               "the breathing loop has no autonomous wake-up deadline")

        let tennisFrames = frames("PlayTennis", strip: "tennis")
        expect(tennisFrames == Array(0...8), "tennis plays the complete forehand family")

        expect(frames("ClingWall", strip: "wall") == Array(0...2),
               "wall stand uses the first coherent family")
        expect(frames("SitAtWall", strip: "wall") == Array(3...5),
               "wall sit uses the second coherent family")

        func holds(_ action: String) -> [Double] {
            poses(action).compactMap { $0["hold"] as? Double }
        }
        expect(holds("RestSettle").allSatisfy { $0 >= 0.40 },
               "sleep settles at a calm readable tempo")

        let behaviors = (root["behaviors"] as! [[String: Any]]).reduce(
            into: [String: [String: Any]]()) {
                $0[$1["name"] as! String] = $1
            }
        let standNext = ((behaviors["Stand"]?["next"] as? [String: Any])?["refs"]
                         as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        expect(!standNext.contains("WalkLeft") && !standNext.contains("WalkRight"),
               "ordinary idle behavior stays in place instead of roaming the desktop")
        expect(behaviors["WalkLeft"]?["frequency"] as? Int == 0
               && behaviors["WalkRight"]?["frequency"] as? Int == 0
               && behaviors["Wander"]?["frequency"] as? Int == 0,
               "walking remains available to packs but is not chosen randomly")
        let quietCondition = behaviors["QuietBreathe"]?["when"] as? String ?? ""
        expect(quietCondition.contains("focusSession")
               && quietCondition.contains("deepWork")
               && quietCondition.contains("focused"),
               "Focus and inferred deep work share the quiet in-place behavior")
        let reflectingCondition = behaviors["Reflecting"]?["when"] as? String ?? ""
        expect(behaviors["Reflecting"]?["action"] as? String == "ReflectTogether"
               && reflectingCondition.contains("mimo.mood == 'reflecting'"),
               "Today Journal owns a persistent, anatomy-neutral looking-back behavior")
        let reactions = root["reactions"] as? [String: String] ?? [:]
        expect(reactions["focusComplete"] == "PlayTennis",
               "a completed Focus can celebrate with one installed tennis action")
        expect(reactions["focusCompleteFallback"] == "CelebrateSmall",
               "a body without tennis art still gets one short anatomy-neutral celebration")
        expect(reactions["distractionLoop"] == "SoftNudge"
               && reactions["journalOpened"] == "ReflectTogether"
               && reactions["fatigue"] == "FatiguePause",
               "context signals use three quiet anatomy-neutral fallback reactions")
        let sleepNextBlock = behaviors["RestSleep"]?["next"] as? [String: Any]
        let sleepNext = sleepNextBlock?["refs"] as? [[String: Any]] ?? []
        expect(sleepNext.count == 1
               && sleepNext[0]["name"] as? String == "RestSleep"
               && sleepNext[0]["frequency"] as? Int == 100,
               "sleep breathes indefinitely until an external interaction interrupts it")
        expect(holds("PlayTennis").min() ?? 0 >= 0.16,
               "the fastest tennis beat is still slow enough to read")
        expect(holds("ClingWall").min() ?? 0 >= 0.80,
               "wall ambience changes gently instead of flickering")
        let walkLeftVelocity = poses("WalkLeft").first?["velocity"] as? [Int] ?? []
        expect(abs(walkLeftVelocity.first ?? 1000) <= 68,
               "walk advances calmly, which also slows its distance-driven gait")
    }

    static func main() throws {
        testCatalogMatchesTheUserFacingStarterPack()
        testEveryDefinitionIsAValidCoherentFamilyPlan()
        testGazeMappingFollowsTheCursorAcrossSupportedContracts()
        testGazeWaitsForASettledCursorAndFocusDisablesIt()
        testTennisBallOwnsOneDeterministicNineFrameTrajectory()
        try testDefaultBehaviorPackUsesOnlyStarterContractFrames()
        print("starter action catalog tests passed")
    }
}
