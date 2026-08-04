// sources: reflection_core.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ReflectionBrowserUITests {
    static func main() throws {
        let html = try String(contentsOfFile: "mac/reflection.html", encoding: .utf8)
        let overlay = try String(contentsOfFile: "mac/overlay.html", encoding: .utf8)
        let main = try String(contentsOfFile: "mac/main.swift", encoding: .utf8)
        let controller = try String(
            contentsOfFile: "mac/reflection_browser.swift", encoding: .utf8)
        let core = try String(contentsOfFile: "mac/reflection_core.swift", encoding: .utf8)
        let model = try String(contentsOfFile: "mac/reflection_model.swift", encoding: .utf8)
        let common = try String(contentsOfFile: "mac/common.sh", encoding: .utf8)
        let build = try String(contentsOfFile: "mac/build.sh", encoding: .utf8)
        let product = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)

        for contract in ["Meaningful activity trail", "Daily reflection", "Learning materials",
                         "activityBlocks", "learningMaterials", "reflectionLoad",
                         "原始证据", "时间流向"] {
            expect(html.contains(contract), "Daily Trail exposes \(contract)")
        }
        for bridge in ["type:'ready'", "type:'setRange'", "type:'savePrivacy'",
                       "type:'synthesize'", "type:'openExternal'"] {
            expect(html.contains(bridge), "web UI exposes bridge action \(bridge)")
        }
        expect(html.contains("conic-gradient") && html.contains("class=\"donut\"")
               && html.contains("class=\"timeline\"")
               && html.contains("materials-grid"),
               "the dashboard visualizes category share, chronology, and learning material cards")
        expect(html.contains("raw-toggle") && html.contains("raw-events")
               && html.contains("data-evidence") && html.contains("locateEvidence"),
               "raw evidence stays expandable and reflection claims locate their source")
        expect(html.contains("ignoredApps") && html.contains("ignoredDomains")
               && html.contains("过滤只影响 Daily Trail，不删除原始日志"),
               "privacy exclusions remain visible and non-destructive")
        expect(html.contains("reflectionFixture") && html.contains("nokey")
               && html.contains("empty") && html.contains("error"),
               "stable populated, empty, error, and no-key fixtures remain available")
        expect(!html.lowercased().contains("notion")
               && !html.contains("writeback") && !html.contains("saveConnection"),
               "the product surface has no remote-notes connection or writeback path")
        expect(!html.contains("console.log") && !html.contains("console.debug"),
               "private reflection content is not emitted to browser diagnostics")

        expect(core.contains("ActivityBlockBuilder")
               && core.contains("LearningMaterialExtractor")
               && core.contains("DailyActivitySnapshot")
               && core.contains("LocalActivityReflector"),
               "local events become blocks, materials, dashboard metrics, and reflection")
        expect(model.contains("Never claim a task was completed")
               && model.contains("For every supplied learning material")
               && model.contains("store\": false")
               && model.contains("SensitiveURLScrubber.scrub"),
               "optional AI enrichment is honest, bounded, no-store, and URL-scrubbed")

        expect(overlay.contains("openReflection") && overlay.contains("今日轨迹")
               && overlay.contains("真正做过的事"),
               "Today and Week journal link to the local Daily Trail")
        expect(main.contains("ReflectionBrowserController(root: logDir)")
               && main.contains("openReflectionBrowser")
               && main.contains("今日轨迹…")
               && !main.contains("refreshFromNotionIfConfigured"),
               "the local dashboard is integrated without launch-time remote sync")
        let fixtureGuard = main.range(of: "if reflectionBrowser.isFixtureMode")
        let productionPanelStart = main.range(of: "buildPanel()")
        expect(fixtureGuard != nil && productionPanelStart != nil
               && fixtureGuard!.lowerBound < productionPanelStart!.lowerBound
               && controller.contains("if fixtureName != nil")
               && controller.contains("if type == \"ready\""),
               "native fixtures remain hermetic and open before production tracking")
        expect(controller.contains("OpenAIReflectionModel(keyReader:")
               && controller.contains("MimoSecret.openAI.isConfigured")
               && controller.contains("确认 AI 总结范围")
               && controller.contains("No screen contents, keystrokes"),
               "AI enrichment uses the existing optional provider behind native scope confirmation")
        expect(controller.contains("window.__mimoReflectionFixture")
               && controller.contains("injectionTime: .atDocumentStart")
               && controller.contains("webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)"),
               "offline visual fixtures load through the same bundled HTML boundary")
        expect(controller.contains("isTrustedBridgeFrame")
               && controller.contains("message.frameInfo.isMainFrame")
               && controller.contains("[\"http\", \"https\"].contains(scheme)"),
               "only the trusted main frame can bridge and external URLs are scheme-limited")
        expect(controller.contains("activityGeneration")
               && controller.contains("analysisGeneration")
               && controller.contains("analysisTask?.cancel()"),
               "stale local reads and AI responses cannot replace a newer range")
        expect(product.contains("reflectionBrowser.activityHistoryDidChange()")
               && product.contains("activityHistoryDidChange(resetAll: true)")
               && !product.contains("removeNotionCache"),
               "existing erase controls invalidate the local derived view")

        for source in ["reflection_core.swift", "reflection_model.swift",
                       "reflection_browser.swift"] {
            expect(common.contains(source), "release compilation includes \(source)")
        }
        expect(!common.contains("notion_reflection.swift"),
               "the removed integration is absent from release compilation")
        expect(build.contains("reflection.html"),
               "the Daily Trail resource is bundled and previewable")
        expect(overlay.contains("if (Fam.paused || !Fam.cur) return;")
               && overlay.contains("Fam.cur = {...Fam.cur, t0:Date.now()}"),
               "pause and forget cannot recreate erased activity through checkpoints")

        print("reflection browser UI tests passed")
    }
}
