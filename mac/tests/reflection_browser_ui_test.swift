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

        for contract in ["今日手记", "Today Journal", "icon-focus", "icon-flow", "icon-reflect",
                         "activityBlocks", "learningMaterials", "reflectionLoad",
                         "原始记录", "一天的节奏"] {
            expect(html.contains(contract), "Today Journal exposes \(contract)")
        }
        for bridge in ["type:'ready'", "type:'setRange'", "type:'savePrivacy'",
                       "type:'synthesize'", "type:'openExternal'"] {
            expect(html.contains(bridge), "web UI exposes bridge action \(bridge)")
        }
        expect(html.contains("conic-gradient") && html.contains("class=\"donut\"")
               && html.contains("class=\"timeline\"")
               && html.contains("materials-grid"),
               "the dashboard visualizes category share, chronology, and learning material cards")
        expect(html.contains("journeyRibbon") && html.contains("half-hour-chapter")
               && html.contains("chapter-track") && html.contains("buildHalfHourChapters")
               && html.contains("journey-preview") && html.contains("journey-phase")
               && html.contains("activity-hover") && html.contains("material-insight-overlay"),
               "the day journey presents activity on strict half-hour chapters with evidence texture")
        expect(html.contains("rangeDropZone") && html.contains("draggable=\"true\"")
               && html.contains("dragstart") && html.contains("drop")
               && html.contains("renderPinnedRange")
               && html.contains("range-boundary"),
               "a half-hour can be dragged into the lower trail as an explicitly bounded interval")
        expect(html.contains("const uiIcon=") && html.contains("categoryIcon")
               && html.contains("metric-primary") && html.contains("activity-icon")
               && html.contains("reflection-section-title"),
               "line icons create a consistent attention hierarchy across metrics and evidence")
        expect(html.contains("identitySource") && html.contains("identityIcon")
               && html.contains("identity-image") && html.contains("/favicon.ico")
               && html.contains("state.appIcons"),
               "activity identity uses real app artwork and each website's own favicon")
        expect(!html.contains("overviewSummary")
               && !html.contains("reflectionHeadline")
               && !html.contains("journeyMapSubtitle")
               && !html.contains("trailSubtitle")
               && !html.contains("materialsSubtitle"),
               "repeated explanatory copy is removed from the focused journal surface")
        expect(html.contains("journeyPreview") && html.contains("journeyAsk")
               && html.contains("updateJourneyPreview")
               && html.contains("addEventListener('focusin'")
               && !html.contains("journey-popover"),
               "journey hover context uses one reserved preview dock and can seed Looking Back")
        expect(html.contains("prompt-suggestion")
               && html.contains("focusStartMS") && html.contains("focusEndMS")
               && controller.contains("focusRange"),
               "Looking Back can ground a question in the selected half-hour")
        expect(!html.contains("left:calc(100% + 15px)")
               && !html.contains("@media(max-width:1180px){.activity-hover")
               && html.contains(".activity-main:hover + .activity-hover"),
               "activity context expands in its own card instead of covering adjacent content")
        expect(html.contains(".trail-panel .section-head{display:block}"),
               "trail filters have a stable row instead of colliding with the heading")
        expect(html.contains("raw-toggle") && html.contains("raw-events")
               && html.contains("data-evidence") && html.contains("locateEvidence"),
               "raw evidence stays expandable and reflection claims locate their source")
        expect(html.contains("ignoredApps") && html.contains("ignoredDomains")
               && html.contains("过滤只影响今日手记，不删除原始日志"),
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
               && model.contains("SensitiveURLScrubber.scrub")
               && model.contains("productivity-dashboard jargon")
               && model.contains("structuredOutputFormat"),
               "optional enrichment is honest, human, bounded, structured, no-store, and URL-scrubbed")

        expect(overlay.contains("openReflection") && overlay.contains("快览")
               && overlay.contains("今日手记"),
               "Quick Look links to the full Today Journal")
        expect(main.contains("ReflectionBrowserController(root: logDir)")
               && main.contains("openReflectionBrowser")
               && main.contains("快览  (⌥Space)")
               && main.contains("今日手记…")
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
               && controller.contains("voiceLanguage() == \"en\"")
               && controller.contains("再看一眼今天")
               && controller.contains("No screen contents or keystrokes"),
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
        expect(controller.contains("appIconsObject")
               && controller.contains("indexInstalledApplications")
               && controller.contains("appIconDataURI")
               && core.contains("bundleIdentifier")
               && main.contains("jsonStr(bid)")
               && overlay.contains("bundleID: bundleID || ''"),
               "native app bundle identity is retained and projected as a local icon")
        expect(product.contains("reflectionBrowser.activityHistoryDidChange()")
               && product.contains("activityHistoryDidChange(resetAll: true)")
               && product.contains("reflectionBrowser.providerConfigurationDidChange()")
               && !product.contains("removeNotionCache"),
               "erase and provider-setting changes immediately refresh the local derived view")

        for source in ["reflection_core.swift", "reflection_model.swift",
                       "reflection_browser.swift"] {
            expect(common.contains(source), "release compilation includes \(source)")
        }
        expect(!common.contains("notion_reflection.swift"),
               "the removed integration is absent from release compilation")
        expect(build.contains("reflection.html"),
               "the Today Journal resource is bundled and previewable")
        expect(overlay.contains("if (Fam.paused || !Fam.cur) return;")
               && overlay.contains("Fam.cur = {...Fam.cur, t0:Date.now()}"),
               "pause and forget cannot recreate erased activity through checkpoints")

        print("reflection browser UI tests passed")
    }
}
