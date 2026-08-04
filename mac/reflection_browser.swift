// Mimo Today Journal — native AppKit/WKWebView host.
//
// The surface is local-first: raw activity is read from Mimo's archive and
// transformed on device. Optional AI enrichment requires a native scope
// confirmation. No remote notes service or writeback path is part of this UI.

import AppKit
import Foundation
import WebKit

final class ReflectionBrowserController: NSObject, NSWindowDelegate,
                                         WKNavigationDelegate,
                                         WKScriptMessageHandler {
    private static let bridgeName = "reflection"

    private let root: URL
    private let browserRoot: URL
    private let stateURL: URL
    private let fixtureName: String?
    private var state: DailyTrailPersistedState
    private var reflectionModel: ReflectionModel?
    private var modelWasExplicitlySet = false

    private var snapshot: DailyActivitySnapshot
    private var reflection: DailyReflection
    private var activityStatus = "idle"
    private var activityMessage: String?
    private var activityError: String?
    private var analysisStatus = "local"
    private var analysisMessage: String?
    private var analysisError: String?
    private var pageReady = false
    private var activityGeneration = UUID()
    private var analysisGeneration = UUID()
    private var analysisTask: Task<Void, Never>?

    private(set) var window: NSWindow?
    private var webView: WKWebView?

    var isFixtureMode: Bool { fixtureName != nil }

    init(root: URL) {
        self.root = root
        fixtureName = Self.fixtureFromProcess()
        browserRoot = root.appendingPathComponent("ReflectionBrowser", isDirectory: true)
        stateURL = browserRoot.appendingPathComponent("daily-trail-state.json", isDirectory: false)
        state = Self.loadState(from: stateURL) ?? DailyTrailPersistedState()
        let initialRange = ReflectionDateRange.today()
        snapshot = .build(range: initialRange, events: [])
        reflection = LocalActivityReflector.build(snapshot: snapshot)
        reflectionModel = fixtureName == nil && MimoSecret.openAI.isConfigured
            ? OpenAIReflectionModel(keyReader: { MimoSecret.openAI.read() }) : nil
        super.init()
    }

    deinit {
        analysisTask?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeName)
    }

    func setModel(_ model: ReflectionModel?) {
        invalidateAnalysis()
        modelWasExplicitlySet = true
        reflectionModel = model
        pushState()
    }

    func present() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.present() must run on the main thread")
        if fixtureName == nil, !modelWasExplicitlySet {
            reflectionModel = MimoSecret.openAI.isConfigured
                ? OpenAIReflectionModel(keyReader: { MimoSecret.openAI.read() }) : nil
        }
        if window == nil { buildWindow() }
        if fixtureName == nil { refreshActivities() }
        guard let window else { return }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @discardableResult
    func activityHistoryDidChange(resetAll: Bool = false) -> Bool {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.activityHistoryDidChange() must run on the main thread")
        invalidateAnalysis()
        var cleared = true
        if resetAll {
            state = DailyTrailPersistedState()
            // Delete retired integration artifacts only inside the existing,
            // explicitly confirmed “Delete Everything” flow.
            for name in ["reflection-state.json", "notion-cache.json",
                         "writeback-ledger.json", "daily-trail-state.json"] {
                let url = browserRoot.appendingPathComponent(name, isDirectory: false)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do { try FileManager.default.removeItem(at: url) }
                catch { cleared = false }
            }
        }
        refreshActivities()
        return persistState() && cleared
    }

    func activityArchiveDidPrune() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.activityArchiveDidPrune() must run on the main thread")
        invalidateAnalysis()
        refreshActivities()
    }

    // MARK: - Window and bridge boundary

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: Self.bridgeName)
        if let fixtureName,
           let data = try? JSONEncoder().encode(fixtureName),
           let json = String(data: data, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__mimoReflectionFixture = \(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let frame = NSRect(x: 0, y: 0, width: 1_240, height: 800)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true

        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = preferredLanguage.hasPrefix("zh") ? "Mimo · 今日手记" : "Mimo · Today Journal"
        window.minSize = NSSize(width: 940, height: 640)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.webView = webView
        self.window = window

        guard let resourceRoot = Bundle.main.resourceURL else {
            showNativeError("Today Journal resources are unavailable.")
            return
        }
        let html = resourceRoot.appendingPathComponent("reflection.html", isDirectory: false)
        webView.loadFileURL(html, allowingReadAccessTo: resourceRoot)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView,
              let url = navigationAction.request.url,
              isBundledResource(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func isBundledResource(_ url: URL) -> Bool {
        guard url.isFileURL, let resourceRoot = Bundle.main.resourceURL else { return false }
        let root = resourceRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func isTrustedBridgeFrame(_ message: WKScriptMessage) -> Bool {
        guard message.name == Self.bridgeName, message.frameInfo.isMainFrame,
              let webView, message.webView === webView,
              let url = message.frameInfo.request.url,
              isBundledResource(url), url.lastPathComponent == "reflection.html" else { return false }
        return true
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard isTrustedBridgeFrame(message),
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if fixtureName != nil {
            if type == "ready" { pageReady = true }
            return
        }
        switch type {
        case "ready":
            pageReady = true
            pushState()
        case "setRange": setRange(body)
        case "savePrivacy": savePrivacy(body)
        case "synthesize": beginSynthesis(body)
        case "openExternal":
            if let raw = body["url"] as? String { openExternal(raw) }
        default: break
        }
    }

    // MARK: - Local activity

    private var currentRange: ReflectionDateRange {
        switch state.rangeMode {
        case "week": return .week()
        case "custom":
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: state.customStart ?? Date())
            let inclusiveEnd = calendar.startOfDay(for: state.customEnd ?? state.customStart ?? Date())
            let end = calendar.date(byAdding: .day, value: 1, to: inclusiveEnd)
                ?? inclusiveEnd.addingTimeInterval(86_400)
            return .init(start: start, end: end)
        default: return .today()
        }
    }

    private func setRange(_ body: [String: Any]) {
        let mode = (body["mode"] as? String ?? "today").lowercased()
        switch mode {
        case "week": state.rangeMode = "week"
        case "custom":
            guard let startRaw = body["start"] as? String,
                  let endRaw = body["end"] as? String,
                  let start = Self.dayFormatter.date(from: startRaw),
                  let end = Self.dayFormatter.date(from: endRaw), end >= start else {
                activityStatus = "error"
                activityError = "Choose a valid date range."
                pushState()
                return
            }
            state.rangeMode = "custom"
            state.customStart = start
            state.customEnd = end
        default: state.rangeMode = "today"
        }
        invalidateAnalysis()
        persistState()
        refreshActivities()
    }

    private func savePrivacy(_ body: [String: Any]) {
        state.ignoredApps = cleanList(body["ignoredApps"])
        state.ignoredDomains = cleanList(body["ignoredDomains"]).map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }.filter { !$0.isEmpty }
        invalidateAnalysis()
        persistState()
        refreshActivities()
    }

    private func cleanList(_ value: Any?) -> [String] {
        let values = value as? [String] ?? []
        return values.reduce(into: []) { output, raw in
            let item = String(raw.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty && !output.contains(item) { output.append(item) }
        }
    }

    private func refreshActivities() {
        let generation = UUID()
        activityGeneration = generation
        activityStatus = "loading"
        activityMessage = "Reading local activity…"
        activityError = nil
        pushState()
        let range = currentRange
        let urls = activityLogURLs()
        let ignoredApps = Set(state.ignoredApps.map {
            $0.folding(options: [.caseInsensitive], locale: .current)
        })
        let ignoredDomains = state.ignoredDomains
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ActivityJSONLParser.read(urls: urls, range: range)
            let visible = result.events.filter { event in
                let app = event.app.folding(options: [.caseInsensitive], locale: .current)
                guard !ignoredApps.contains(app) else { return false }
                guard let domain = event.domain?.lowercased() else { return true }
                return !ignoredDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
            }
            let snapshot = DailyActivitySnapshot.build(range: range, events: visible)
            let local = LocalActivityReflector.build(snapshot: snapshot)
            DispatchQueue.main.async {
                guard let self, self.activityGeneration == generation else { return }
                self.snapshot = snapshot
                self.reflection = local
                self.analysisStatus = "local"
                self.analysisMessage = nil
                self.analysisError = nil
                let malformed = result.malformedLineNumbers.count
                let unreadable = result.unreadableSourceIDs.count
                if !urls.isEmpty && unreadable == urls.count {
                    self.activityStatus = "error"
                    self.activityMessage = nil
                    self.activityError = "Mimo could not read the local activity archive."
                } else if malformed > 0 || unreadable > 0 {
                    self.activityStatus = "warning"
                    self.activityMessage = "Loaded available activity; skipped \(malformed) malformed line(s) and \(unreadable) unreadable file(s)."
                    self.activityError = nil
                } else {
                    self.activityStatus = "ready"
                    self.activityMessage = nil
                    self.activityError = nil
                }
                self.pushState()
            }
        }
    }

    private func activityLogURLs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("activity-")
                && $0.lastPathComponent.hasSuffix(".jsonl")
        }
    }

    // MARK: - Optional AI enrichment

    private func beginSynthesis(_ body: [String: Any]) {
        guard activityStatus != "loading", !snapshot.events.isEmpty else {
            analysisStatus = "error"
            analysisError = "There is no loaded activity to summarize."
            pushState()
            return
        }
        guard let model = reflectionModel else {
            analysisStatus = "error"
            analysisError = ReflectionModelError.missingKey.errorDescription
            pushState()
            return
        }
        guard confirmModelScope() else { return }
        let prompt = (body["prompt"] as? String).map { String($0.prefix(2_000)) }
        let input = ReflectionModelInput(snapshot: snapshot, prompt: prompt)
        let generation = UUID()
        analysisGeneration = generation
        analysisTask?.cancel()
        analysisStatus = "loading"
        analysisMessage = "Building a grounded daily reflection…"
        analysisError = nil
        pushState()
        analysisTask = Task { [weak self] in
            do {
                let output = try await model.synthesize(input)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else { return }
                    self.reflection = output
                    self.analysisStatus = "ready"
                    self.analysisMessage = "AI summary grounded in local activity"
                    self.analysisError = nil
                    self.pushState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else { return }
                    self.analysisStatus = "error"
                    self.analysisMessage = nil
                    self.analysisError = (error as? LocalizedError)?.errorDescription
                        ?? "Mimo could not build the summary."
                    self.pushState()
                }
            }
        }
    }

    private func invalidateAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisGeneration = UUID()
        analysisStatus = "local"
        analysisMessage = nil
        analysisError = nil
    }

    private func confirmModelScope() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = preferredLanguage.hasPrefix("zh") ? "确认 AI 总结范围" : "Confirm AI summary scope"
        let range = "\(Self.dayFormatter.string(from: snapshot.range.start)) → \(Self.dayFormatter.string(from: snapshot.range.end.addingTimeInterval(-1)))"
        if preferredLanguage.hasPrefix("zh") {
            alert.informativeText = "日期：\(range)\n\n将发送 \(snapshot.events.count) 条活动元数据和 \(snapshot.materials.count) 个学习材料标题。URL 中的凭证、敏感参数和片段会先移除；不会发送屏幕内容、键盘输入或 Notion 数据。"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
        } else {
            alert.informativeText = "Date: \(range)\n\nSend metadata for \(snapshot.events.count) activities and titles for \(snapshot.materials.count) learning materials. Credentials, sensitive URL parameters, and fragments are removed first. No screen contents, keystrokes, or Notion data are sent."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openExternal(_ raw: String) {
        guard raw.utf8.count <= 8_192,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - HTML projection

    private func pushState() {
        guard pageReady, let webView else { return }
        let payload = htmlPayload()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.reflectionLoad(\(json))", completionHandler: nil)
    }

    private func htmlPayload() -> [String: Any] {
        let summaries = Dictionary(uniqueKeysWithValues: reflection.materialSummaries.map {
            ($0.materialID, $0)
        })
        return [
            "config": [
                "language": preferredLanguage,
                "modelConfigured": reflectionModel != nil,
                "fixture": false,
                "ignoredApps": state.ignoredApps,
                "ignoredDomains": state.ignoredDomains,
            ],
            "range": [
                "mode": state.rangeMode,
                "start": Self.dayFormatter.string(from: snapshot.range.start),
                "end": Self.dayFormatter.string(from: snapshot.range.end.addingTimeInterval(-1)),
            ],
            "metrics": [
                "activeSeconds": snapshot.activeDurationMS / 1_000,
                "focusSeconds": snapshot.focusDurationMS / 1_000,
                "contextSwitches": snapshot.contextSwitchCount,
                "blockCount": snapshot.blocks.count,
                "materialCount": snapshot.materials.count,
            ],
            "categories": snapshot.categories.map { summary in
                ["id": summary.category.rawValue,
                 "durationSeconds": summary.durationMS / 1_000,
                 "blockCount": summary.blockCount,
                 "share": summary.share] as [String: Any]
            },
            "activityBlocks": snapshot.blocks.map(blockObject),
            "learningMaterials": snapshot.materials.map { material in
                materialObject(material, summary: summaries[material.id])
            },
            "reflection": reflectionObject(),
            "status": statusObject(),
        ]
    }

    private func blockObject(_ block: ActivityBlock) -> [String: Any] {
        let eventByID = Dictionary(uniqueKeysWithValues: snapshot.events.map { ($0.id, $0) })
        return [
            "id": block.id, "title": block.title, "category": block.category.rawValue,
            "start": Self.timestamp(Date(timeIntervalSince1970: block.startedAtMS / 1_000)),
            "end": Self.timestamp(Date(timeIntervalSince1970: block.endedAtMS / 1_000)),
            "activeSeconds": block.activeDurationMS / 1_000,
            "elapsedSeconds": block.elapsedDurationMS / 1_000,
            "apps": block.apps, "domains": block.domains,
            "revisits": block.revisitCount, "contextSwitches": block.contextSwitchCount,
            "eventIDs": block.eventIDs,
            "events": block.eventIDs.compactMap { eventByID[$0] }.map(Self.eventObject),
        ]
    }

    private static func eventObject(_ event: ActivityEvent) -> [String: Any] {
        var output: [String: Any] = [
            "id": event.id,
            "start": timestamp(Date(timeIntervalSince1970: event.startedAtMS / 1_000)),
            "end": timestamp(Date(timeIntervalSince1970: event.endedAtMS / 1_000)),
            "durationSeconds": event.durationMS / 1_000,
            "app": event.app, "title": event.displayTitle,
            "category": ActivityCategory.classify(event).rawValue,
            "rawCategory": event.category,
            "revisit": event.isRevisit, "contextSwitch": event.isContextSwitch,
        ]
        if let domain = event.domain { output["domain"] = domain }
        if let url = event.fullURL { output["url"] = url }
        return output
    }

    private func materialObject(_ material: LearningMaterial,
                                summary: LearningMaterialSummary?) -> [String: Any] {
        var output: [String: Any] = [
            "id": material.id, "title": material.title, "kind": material.kind.rawValue,
            "durationSeconds": material.durationMS / 1_000,
            "visits": material.encounterCount,
            "overview": summary?.overview ?? material.localSummary,
            "keyIdeas": summary?.keyIdeas ?? [],
            "evidenceIDs": summary?.evidenceIDs ?? material.eventIDs,
            "aiEnhanced": summary?.isAIEnhanced ?? false,
        ]
        if let domain = material.domain { output["domain"] = domain }
        if let url = material.url { output["url"] = url }
        if let relevance = summary?.relevance { output["relevance"] = relevance }
        return output
    }

    private func reflectionObject() -> [String: Any] {
        ["headline": reflection.headline, "summary": reflection.summary,
         "aiEnhanced": reflection.isAIEnhanced,
         "sections": reflection.sections.map { section in
            ["id": section.kind.rawValue,
             "statements": section.statements.map { statement in
                ["text": statement.text, "kind": statement.claimKind.rawValue,
                 "evidenceIDs": statement.evidenceIDs] as [String: Any]
             }] as [String: Any]
         }]
    }

    private func statusObject() -> [String: Any] {
        var output: [String: Any] = [
            "activity": activityStatus, "analysis": analysisStatus,
        ]
        if let activityMessage { output["activityMessage"] = activityMessage }
        if let activityError { output["activityError"] = activityError }
        if let analysisMessage { output["analysisMessage"] = analysisMessage }
        if let analysisError { output["analysisError"] = analysisError }
        return output
    }

    // MARK: - State and helpers

    @discardableResult
    private func persistState() -> Bool {
        do {
            try FileManager.default.createDirectory(at: browserRoot,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
            return true
        } catch { return false }
    }

    private static func loadState(from url: URL) -> DailyTrailPersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DailyTrailPersistedState.self, from: data)
    }

    private static func fixtureFromProcess() -> String? {
        let allowed = Set(["1", "empty", "error", "nokey", "notoken"])
        if let value = ProcessInfo.processInfo.environment["MIMO_REFLECTION_FIXTURE"],
           allowed.contains(value) { return value }
        let prefix = "--reflection-fixture="
        return ProcessInfo.processInfo.arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(prefix) else { return nil }
            let value = String(argument.dropFirst(prefix.count))
            return allowed.contains(value) ? value : nil
        }.first
    }

    private var preferredLanguage: String { Locale.preferredLanguages.first ?? "zh-CN" }

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = .current
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private func showNativeError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = preferredLanguage.hasPrefix("zh") ? "Mimo 今日手记" : "Mimo Today Journal"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct DailyTrailPersistedState: Codable {
    var rangeMode: String
    var customStart: Date?
    var customEnd: Date?
    var ignoredApps: [String]
    var ignoredDomains: [String]

    init(rangeMode: String = "today", customStart: Date? = nil,
         customEnd: Date? = nil, ignoredApps: [String] = [],
         ignoredDomains: [String] = []) {
        self.rangeMode = rangeMode
        self.customStart = customStart
        self.customEnd = customEnd
        self.ignoredApps = ignoredApps
        self.ignoredDomains = ignoredDomains
    }

    private enum CodingKeys: String, CodingKey {
        case rangeMode, customStart, customEnd, ignoredApps, ignoredDomains
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rangeMode = try values.decodeIfPresent(String.self, forKey: .rangeMode) ?? "today"
        customStart = try values.decodeIfPresent(Date.self, forKey: .customStart)
        customEnd = try values.decodeIfPresent(Date.self, forKey: .customEnd)
        ignoredApps = try values.decodeIfPresent([String].self, forKey: .ignoredApps) ?? []
        ignoredDomains = try values.decodeIfPresent([String].self, forKey: .ignoredDomains) ?? []
    }
}
