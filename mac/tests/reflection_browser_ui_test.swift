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
        let common = try String(contentsOfFile: "mac/common.sh", encoding: .utf8)
        let build = try String(contentsOfFile: "mac/build.sh", encoding: .utf8)
        let product = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)

        for contract in ["原始活动轨迹", "手记原文", "综合与对话",
                         "activityGroups", "reflectionLoad", "selectedEvidenceIDs"] {
            expect(html.contains(contract), "Reflection Browser preserves \(contract)")
        }
        for bridge in ["'ready'", "'setRange'", "'sync'", "'saveConnection'",
                       "'clearToken'", "'savePrivacy'", "'synthesize'", "'saveMark'",
                       "'removeMark'", "'previewWriteback'", "'confirmWriteback'"] {
            expect(html.contains(bridge), "web UI exposes bridge action \(bridge)")
        }
        expect(html.contains("appFilter") && html.contains("domainFilter")
               && html.contains("categoryFilter"),
               "raw activity supports explicit App, domain, and category filters")
        expect(html.contains("target.closest('details')?.setAttribute('open','')")
               && html.contains("renderActivities();renderReflections();renderSynthesis()"),
               "evidence locating reveals collapsed activity and re-renders both source columns")
        expect(html.contains("writebackTargets")
               && html.contains("写回目标页面")
               && html.contains("targetTitle")
               && html.contains("els.writebackBtn.disabled=(!state.synthesis&&!state.writebackDraft)||busy")
               && html.contains(".quiet-btn:disabled"),
               "writeback preview requires a named page destination instead of a bare container ID")
        expect(html.contains("markable-response")
               && controller.contains("remapCurrentMarksToConversation()")
               && controller.contains("ReflectionMarkScope.retained")
               && controller.contains("allowedEvidenceIDs: synthesisEvidenceIDs")
               && controller.contains("evidenceIDs: evidenceIDs(forSourceID: responseID)")
               && !controller.contains("highlightedTexts()")
               && controller.contains("locationUTF16")
               && html.contains("locationUTF16")
               && !controller.contains("state.synthesis = synthesis\n        state.marks = []"),
               "marks remain exact, removable, and reusable across assistant turns")
        expect(html.contains("class=\"chat-box global-chat\"")
               && html.contains("id=\"dictationBtn\"")
               && html.contains("按两次 Fn")
               && !html.contains("<section class=\"panel\" aria-labelledby=\"synthesisTitle\">\n      <div class=\"chat-box"),
               "Ask Mimo composer spans the workspace and exposes an honest macOS Dictation affordance")
        expect(html.contains("ignoredAppsInput") && html.contains("ignoredDomainsInput"),
               "privacy exclusions are user configurable")
        expect(html.contains("fixture=1|empty|error|notoken")
               || (html.contains("reflectionFixture") && html.contains("notoken")),
               "stable offline visual fixtures remain available")
        expect(html.contains("Token 仅保存到 macOS Keychain")
               && html.contains("确认写回"),
               "credential and explicit-writeback boundaries are visible")
        expect(html.contains("id=\"targetKindSelect\"")
               && html.contains("targetKind:els.targetKindSelect.value")
               && controller.contains("case \"database\": hint = .database")
               && controller.contains("NotionTargetParser.parse(targetRaw, hint: hint)"),
               "ambiguous Notion URLs expose and honor an explicit target type")
        expect(!html.contains("console.log") && !html.contains("console.debug"),
               "reflection content is not emitted to browser diagnostics")
        expect(!html.contains("reflection-post"),
               "bridge payloads, including connection tokens, are not rebroadcast as DOM events")

        expect(overlay.contains("openReflection") && overlay.contains("深度回望"),
               "Today and Week journal expose the quiet native entry")
        expect(main.contains("ReflectionBrowserController(root: logDir)")
               && main.contains("openReflectionBrowser"),
               "the browser is integrated into the existing AppKit app")
        let fixtureGuard = main.range(of: "if reflectionBrowser.isFixtureMode")
        let productionPanelStart = main.range(of: "buildPanel()")
        expect(fixtureGuard != nil && productionPanelStart != nil
               && fixtureGuard!.lowerBound < productionPanelStart!.lowerBound
               && controller.contains("if fixtureName != nil")
               && controller.contains("if type == \"ready\""),
               "native fixtures open before production tracking and accept only the ready bridge")
        expect(controller.contains("OpenAIReflectionModel(keyReader:")
               && controller.contains("MimoSecret.openAI.isConfigured")
               && controller.contains("Confirm reflection scope")
               && controller.contains("Date range:"),
               "production analysis uses the existing optional provider behind a native scope gate")
        expect(controller.contains("window.__mimoReflectionFixture")
               && controller.contains("injectionTime: .atDocumentStart")
               && controller.contains("webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)")
               && !controller.contains("components?.queryItems = [.init(name: \"fixture\""),
               "native fixtures keep WKWebView's load URL a valid plain file URL")
        expect(controller.contains("allowedPageIDs")
               && controller.contains("state.target?.kind == .page")
               && !controller.contains("draft.targetPageID = state.target?.id")
               && !controller.contains("?? reflections.first?.pageID"),
               "database and data-source container IDs are not treated as writable pages")
        expect(controller.contains("analysisGeneration")
               && controller.contains("syncGeneration")
               && controller.contains("writebackConfirming")
               && controller.contains("persist: false")
               && controller.contains("state.writebackPreview = nil")
               && controller.contains("draft.markdown = Self.synthesisMarkdown(synthesis)"),
               "native async boundaries reject stale work and duplicate writeback")
        expect(controller.contains("ReflectionPersistedStateSchema.currentVersion")
               && controller.contains("requiresDerivedReset")
               && controller.contains("resetDerivedState")
               && controller.contains("migrated.writebackPreview = nil")
               && controller.contains("migrated.writebackError = nil"),
               "v1 derived dialogue/drafts migrate fail-closed while connection settings survive")
        let presentStart = controller.range(of: "func present()")!
        let presentEnd = controller.range(of: "func activityHistoryDidChange", range: presentStart.upperBound..<controller.endIndex)!
        let presentBody = String(controller[presentStart.lowerBound..<presentEnd.lowerBound])
        expect(main.contains("reflectionBrowser.refreshFromNotionIfConfigured()")
               && !presentBody.contains("refreshFromNotionIfConfigured()"),
               "Notion refresh runs once at app launch instead of whenever the browser opens")
        expect(controller.contains("notionRefreshSuspended")
               && controller.contains("Sync manually to import it again"),
               "delete-all durably suppresses automatic Notion re-import")
        expect(controller.contains("try notionTokenIsAvailable()")
               && controller.contains("could not read the Notion token from Keychain")
               && controller.contains("preview is only in memory")
               && controller.contains("could not save the local writeback recovery state"),
               "Keychain and critical draft persistence failures remain visible and recoverable")
        expect(controller.contains("activityHistoryDidChange(removeNotionCache:")
               && product.contains("reflectionBrowser.activityHistoryDidChange"),
               "existing forget controls invalidate derived reflection data")
        for source in ["reflection_core.swift", "notion_reflection.swift",
                       "reflection_model.swift", "reflection_browser.swift"] {
            expect(common.contains(source), "release compilation includes \(source)")
        }
        expect(build.contains("reflection.html"),
               "the Reflection Browser resource is bundled and previewable")
        expect(overlay.contains("if (Fam.paused || !Fam.cur) return;")
               && overlay.contains("Fam.cur = {...Fam.cur, t0:Date.now()}"),
               "pause and forget cannot recreate erased activity through checkpoints")

        print("reflection browser UI tests passed")
    }
}
