// sources: starter_action.swift companion_geometry.swift companion_physics.swift companion_sprite.swift companion_expression.swift companion_behavior.swift companion_director.swift companion_window.swift companion_runtime.swift
import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func section(_ source: String, from start: String, until end: String) -> String {
    guard let lower = source.range(of: start),
          let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)
    else { return "" }
    return String(source[lower.lowerBound..<upper.lowerBound])
}

private func oneFrameSprite() -> CompanionSprite {
    let context = CGContext(data: nil, width: 16, height: 16,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 4, y: 2, width: 8, height: 12))
    return CompanionSprite.slice(sheet: context.makeImage()!, frameCount: 1)!
}

@main
struct CompanionActionMenuTests {
    static func main() throws {
        let main = try String(contentsOfFile: "mac/main.swift", encoding: .utf8)
        let runtime = try String(
            contentsOfFile: "mac/companion_runtime.swift", encoding: .utf8)
        let overlay = try String(contentsOfFile: "mac/overlay.html", encoding: .utf8)

        expect(StarterActionCatalog.all.map(\.manifestActionName)
               == ["gaze", "rest", "tennis", "wall"],
               "the desktop menu catalog must remain exactly four stable starter actions")
        expect(StarterActionCatalog.all.map(\.titleZh)
               == ["跟随光标", "睡觉", "打网球", "墙边站着 / 坐着"],
               "the four Chinese menu labels should stay product-facing")

        let menu = section(main, from: "func showCompanionMenu()",
                           until: "@objc func playCompanionAction")
        expect(menu.contains("for definition in StarterActionCatalog.all"),
               "the menu should derive order and labels from the shared catalog")
        expect(menu.contains("actionsMenu.autoenablesItems = false") &&
               menu.contains("companionRuntime.availableActionNames") &&
               menu.contains("installed.contains(definition.manifestActionName)"),
               "AppKit must not re-enable a missing or rejected action strip")
        expect(menu.contains("actionItem.representedObject = definition.manifestActionName"),
               "menu items should carry manifest keys rather than display labels")
        expect(menu.contains("回到自动") && menu.contains("Resume Automatic") &&
               menu.contains("companionRuntime.previewActionName != nil"),
               "manual loops need an explicit return to automatic behavior")
        expect(menu.contains("大小") && menu.contains("Size")
               && menu.contains("companionDisplayScalePercent()")
               && menu.contains("changeCompanionSize"),
               "the familiar menu exposes discoverable small, standard, and large sizes")

        let handler = section(main, from: "@objc func playCompanionAction",
                              until: "// ── hover hot-zone")
        expect(handler.contains("StarterActionCatalog.definition(manifestActionName: name)") &&
               handler.contains("companionRuntime.playInstalledAction(named: name)"),
               "the selector should validate the catalog key and use local runtime playback")
        expect(handler.contains("companionRuntime.previewAction(named: nil)"),
               "Resume Automatic should leave manual preview mode")
        expect(handler.contains("companionDisplayScalePercent")
               && handler.contains("applyCompanionDisplayScale"),
               "quick size choices persist through the same clamped display-size path")
        for paidPath in ["petStarterActionStart", "startStarterActionPack",
                         "PetProvider", "URLSession"] {
            expect(!menu.contains(paidPath) && !handler.contains(paidPath),
                   "right-click playback must never enter paid/API path \(paidPath)")
        }

        let playback = section(runtime, from: "func playInstalledAction(named name: String)",
                               until: "/// Loops one installed action")
        expect(runtime.contains("var availableActionNames: Set<String> { Set(actionSprites.keys) }") &&
               playback.contains("guard actionSprites[name] != nil"),
               "runtime playback should allow only successfully loaded strips")
        expect(playback.contains("beginExplicitGazeFollow") &&
               !playback.contains("if name == \"gaze\" { return previewAction(named: nil) }"),
               "choosing gaze should enter a visible manual cursor-follow mode")
        expect(playback.contains("beginWallSequence") &&
               playback.contains("nearestWallPlacement") &&
               playback.contains("return previewAction(named: name)"),
               "wall should play its complete six-frame sequence at a safe nearest edge")
        expect(runtime.contains("keepWallPreviewInsideSurface")
               && runtime.contains("CompanionWallFrameContainment.correctedAnchorY")
               && runtime.contains("currentFrame.visibleRect"),
               "wall playback must contain each newly presented frame, not only its anchor")

        let sprite = oneFrameSprite()
        let localRuntime = CompanionRuntime()
        localRuntime.setActionSprites(["gaze": sprite, "rest": sprite, "wall": sprite])
        expect(localRuntime.availableActionNames == Set(["gaze", "rest", "wall"]),
               "the menu allow-list should expose only installed runtime sprites")
        localRuntime.spawn(sprite: sprite, at: CGPoint(x: 100, y: 100))
        expect(localRuntime.previewAction(named: "rest") &&
               localRuntime.previewActionName == "rest",
               "an installed local gesture should enter manual playback")
        localRuntime.setSemanticState(
            mood: "focusSession", focusMinutes: 0, streakMinutes: 0)
        expect(localRuntime.mood == "focusSession"
               && localRuntime.previewActionName == nil,
               "starting Focus immediately returns a manual loop to quiet automatic behavior")
        localRuntime.setReflectionActive(true)
        expect(localRuntime.mood == "reflecting" && localRuntime.reflectionActive,
               "an open Today Journal should become the companion's active context")
        localRuntime.setSemanticState(
            mood: "deepWork", focusMinutes: 31, streakMinutes: 31)
        expect(localRuntime.mood == "reflecting",
               "background app updates must not interrupt looking back together")
        localRuntime.setReflectionActive(false)
        expect(localRuntime.mood == "deepWork" && !localRuntime.reflectionActive,
               "closing Today Journal restores the latest underlying activity context")
        let behaviorData = try Data(contentsOf: URL(
            fileURLWithPath: "mac/assets/behavior/default.json"))
        let behaviorPack = try CompanionBehaviorPack.load(data: behaviorData)
        let fallbackDirector = CompanionDirector(
            pack: behaviorPack, availableStrips: [], random: { 0.5 })
        var groundedSnapshot = CompanionSnapshot()
        groundedSnapshot.state = "grounded"
        expect(!fallbackDirector.trigger(
            reactionTo: "focusComplete", snapshot: groundedSnapshot)
               && fallbackDirector.trigger(
                reactionTo: "focusCompleteFallback", snapshot: groundedSnapshot),
               "a body without tennis art has one legal anatomy-neutral celebration")
        expect(localRuntime.playInstalledAction(named: "gaze") &&
               localRuntime.previewActionName == "gaze",
               "choosing gaze should expose a cancellable manual cursor-follow mode")
        expect(localRuntime.previewAction(named: nil) &&
               localRuntime.previewActionName == nil,
               "Resume Automatic should leave explicit cursor-follow mode")
        expect(localRuntime.playInstalledAction(named: "wall") &&
               localRuntime.previewActionName == "wall",
               "choosing wall should enter the complete manual edge sequence")
        expect(localRuntime.previewAction(named: nil) &&
               localRuntime.previewActionName == nil,
               "Resume Automatic should leave the wall sequence and release the edge")
        let wallPlayback = CompanionRuntime.manualPreviewPlaybackSpec(
            for: "wall", frameCount: 6, persisted: nil)
        expect(wallPlayback.frameDurationsSeconds == [0.95, 0.85, 1.25, 1.00, 0.85, 1.25] &&
               wallPlayback.loopStartFrame == 3,
               "manual wall playback should stand once, then keep the sitting-leg loop alive")
        expect(!localRuntime.playInstalledAction(named: "tennis"),
               "an uninstalled action cannot be invoked through the runtime")
        localRuntime.removeAll()

        expect(overlay.contains("fam.addEventListener('contextmenu'") &&
               overlay.contains("type: 'ctxMenu'") &&
               main.contains("case \"ctxMenu\":\n            showCompanionMenu()"),
               "web and native familiars should share the same native menu")
        expect(overlay.contains("? 'focusSession' : (current || 'idle')")
               && overlay.contains("type:'companionEvent',event:'focusComplete'")
               && overlay.contains("function famSetReflectionActive(on)")
               && main.contains("case \"companionEvent\":")
               && main.contains("reflectionBrowser.onVisibilityChanged")
               && main.contains("journalOpened")
               && main.contains("CompanionContextPolicy")
               && runtime.contains("func setSemanticState")
               && runtime.contains("func setReflectionActive")
               && runtime.contains("focusCompleteFallback")
               && runtime.contains("func trigger(event: String)"),
               "real activity, Focus, and Today Journal drive sparse local companion semantics")

        print("companion action menu tests passed")
    }
}
