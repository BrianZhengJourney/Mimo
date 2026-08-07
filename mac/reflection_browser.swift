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
    private let journeyGraphStore: JourneyGraphStore
    private let fixtureName: String?
    private var state: DailyTrailPersistedState
    private var reflectionModel: ReflectionModel?
    private var modelWasExplicitlySet = false

    private var snapshot: DailyActivitySnapshot
    private var journeyGraph: JourneyGraphArchive
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
    private lazy var installedApps = Self.indexInstalledApplications()
    private var journalAppIconCache: [String: String] = [:]

    private(set) var window: NSWindow?
    private var webView: WKWebView?

    var isFixtureMode: Bool { fixtureName != nil }

    init(root: URL) {
        self.root = root
        fixtureName = Self.fixtureFromProcess()
        browserRoot = root.appendingPathComponent("ReflectionBrowser", isDirectory: true)
        stateURL = browserRoot.appendingPathComponent("daily-trail-state.json", isDirectory: false)
        journeyGraphStore = JourneyGraphStore(root: browserRoot)
        state = Self.loadState(from: stateURL) ?? DailyTrailPersistedState()
        let initialRange = ReflectionDateRange.today()
        snapshot = .build(range: initialRange, events: [])
        journeyGraph = JourneyGraphBuilder.build(snapshot: snapshot)
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

    func providerConfigurationDidChange() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.providerConfigurationDidChange() must run on the main thread")
        guard fixtureName == nil, !modelWasExplicitlySet else { return }
        invalidateAnalysis()
        refreshProviderModel()
        pushState()
    }

    func present() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.present() must run on the main thread")
        if fixtureName == nil, !modelWasExplicitlySet {
            refreshProviderModel()
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
            if !journeyGraphStore.purgeAll() { cleared = false }
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
            let journeyGraph = JourneyGraphBuilder.build(snapshot: snapshot)
            let local = LocalActivityReflector.build(snapshot: snapshot)
            DispatchQueue.main.async {
                guard let self, self.activityGeneration == generation else { return }
                self.snapshot = snapshot
                self.journeyGraph = journeyGraph
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
                do {
                    try self.journeyGraphStore.save(journeyGraph)
                } catch {
                    if self.activityStatus != "error" {
                        self.activityStatus = "warning"
                        let graphWarning = self.preferredLanguage.hasPrefix("zh")
                            ? "本地图快照没有保存成功。"
                            : "The local graph snapshot was not saved."
                        self.activityMessage = [self.activityMessage, graphWarning]
                            .compactMap { $0 }.joined(separator: " ")
                    }
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
        refreshProviderModel()
        guard let model = reflectionModel else {
            analysisStatus = "error"
            analysisError = ReflectionModelError.missingKey.userMessage(
                isChinese: preferredLanguage.hasPrefix("zh"))
            pushState()
            return
        }
        let rawPrompt = (body["prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = rawPrompt.isEmpty
            ? (preferredLanguage.hasPrefix("zh")
                ? "请用自然、克制的中文，帮我回看今天。"
                : "Help me look back at today in natural, understated English.")
            : String(rawPrompt.prefix(2_000))
        let focusRange = modelFocusRange(body)
        guard confirmModelScope(focusRange: focusRange) else { return }
        let input = ReflectionModelInput(
            snapshot: snapshot, prompt: prompt, focusRange: focusRange)
        let generation = UUID()
        analysisGeneration = generation
        analysisTask?.cancel()
        analysisStatus = "loading"
        analysisMessage = preferredLanguage.hasPrefix("zh")
            ? "正在把今天轻轻整理一下…" : "Gently putting the day into words…"
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
                    self.analysisMessage = self.preferredLanguage.hasPrefix("zh")
                        ? "整理好了；每句话都可以回到原始记录。"
                        : "Ready; every note can return to its source."
                    self.analysisError = nil
                    self.pushState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else { return }
                    self.analysisStatus = "error"
                    self.analysisMessage = nil
                    if let modelError = error as? ReflectionModelError {
                        self.analysisError = modelError.userMessage(
                            isChinese: self.preferredLanguage.hasPrefix("zh"))
                    } else {
                        self.analysisError = self.preferredLanguage.hasPrefix("zh")
                            ? "这次没能整理好，原始记录没有变化。"
                            : "This pass did not finish; the original journal is unchanged."
                    }
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

    private func refreshProviderModel() {
        guard fixtureName == nil, !modelWasExplicitlySet else { return }
        reflectionModel = MimoSecret.openAI.isConfigured
            ? OpenAIReflectionModel(keyReader: { MimoSecret.openAI.read() }) : nil
    }

    private func modelFocusRange(_ body: [String: Any]) -> ReflectionDateRange? {
        guard let startMS = (body["focusStartMS"] as? NSNumber)?.doubleValue,
              let endMS = (body["focusEndMS"] as? NSNumber)?.doubleValue,
              startMS.isFinite, endMS.isFinite, endMS > startMS else { return nil }
        let start = Date(timeIntervalSince1970: startMS / 1_000)
        let end = Date(timeIntervalSince1970: endMS / 1_000)
        guard start >= snapshot.range.start, end <= snapshot.range.end,
              end.timeIntervalSince(start) <= 30 * 60 + 1 else { return nil }
        return ReflectionDateRange(start: start, end: end)
    }

    private func confirmModelScope(focusRange: ReflectionDateRange? = nil) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = preferredLanguage.hasPrefix("zh")
            ? (focusRange == nil ? "再看一眼今天" : "回看这半小时")
            : (focusRange == nil ? "Take another look at today" : "Look back at this half hour")
        let range = "\(Self.dayFormatter.string(from: snapshot.range.start)) → \(Self.dayFormatter.string(from: snapshot.range.end.addingTimeInterval(-1)))"
        let focusLine = focusRange.map {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: preferredLanguage.hasPrefix("zh") ? "zh_CN" : "en_US")
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: $0.start))—\(formatter.string(from: $0.end))"
        }
        if preferredLanguage.hasPrefix("zh") {
            alert.informativeText = "日期：\(range)\(focusLine.map { "\n本次重点：\($0)" } ?? "")\n\nMimo 会选取最多 240 条代表性活动证据和学习材料标题，交给 OpenAI 帮你整理。URL 中的凭证、敏感参数和片段会先移除；不会发送屏幕内容或键盘输入。"
            alert.addButton(withTitle: "帮我整理")
            alert.addButton(withTitle: "取消")
        } else {
            alert.informativeText = "Date: \(range)\(focusLine.map { "\nFocus: \($0)" } ?? "")\n\nMimo will select up to 240 representative activity records and learning-material titles for OpenAI to organize. Credentials, sensitive URL parameters, and fragments are removed first. No screen contents or keystrokes are sent."
            alert.addButton(withTitle: "Organize it")
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
            "appIcons": appIconsObject(),
            "journeyGraph": journeyGraph.jsonObject() ?? [:],
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
        if let bundleIdentifier = event.bundleIdentifier {
            output["bundleID"] = bundleIdentifier
        }
        return output
    }

    private func appIconsObject() -> [String: String] {
        var preferredBundles: [String: String] = [:]
        for event in snapshot.events {
            let key = Self.normalizedAppName(event.app)
            guard !key.isEmpty else { continue }
            if let bundleIdentifier = event.bundleIdentifier, !bundleIdentifier.isEmpty {
                preferredBundles[key] = bundleIdentifier
            }
        }
        var output: [String: String] = [:]
        let appNames = Set(snapshot.events.map(\.app))
        for appName in appNames {
            let key = Self.normalizedAppName(appName)
            let preferredURL = preferredBundles[key].flatMap {
                installedApps.byBundleIdentifier[$0]
            }
            guard !key.isEmpty,
                  let appURL = preferredURL ?? installedApps.byName[key],
                  let icon = appIconDataURI(at: appURL) else { continue }
            output[key] = icon
        }
        return output
    }

    private func appIconDataURI(at url: URL) -> String? {
        if let cached = journalAppIconCache[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            return nil
        }
        let uri = "data:image/png;base64," + png.base64EncodedString()
        journalAppIconCache[url.path] = uri
        return uri
    }

    private static func normalizedAppName(_ value: String) -> String {
        let base = value.components(separatedBy: " — ").first ?? value
        return base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct InstalledAppIndex {
        var byName: [String: URL] = [:]
        var byBundleIdentifier: [String: URL] = [:]
    }

    private static func indexInstalledApplications() -> InstalledAppIndex {
        let manager = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
        roots.append(manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true))
        var output = InstalledAppIndex()
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
                guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
                    continue
                }
                output.byBundleIdentifier[identifier] = url
                let names = [bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                             url.deletingPathExtension().lastPathComponent]
                for name in names.compactMap({ $0 }) {
                    let key = normalizedAppName(name)
                    if !key.isEmpty { output.byName[key] = url }
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, let identifier = app.bundleIdentifier,
                  let url = app.bundleURL else { continue }
            output.byName[normalizedAppName(name)] = url
            output.byBundleIdentifier[identifier] = url
        }
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
        if !reflection.isAIEnhanced { return localReflectionObject() }
        return ["headline": reflection.headline, "summary": reflection.summary,
         "aiEnhanced": reflection.isAIEnhanced,
         "sections": reflection.sections.map { section in
            ["id": section.kind.rawValue,
             "statements": section.statements.map { statement in
                ["text": statement.text, "kind": statement.claimKind.rawValue,
                 "evidenceIDs": statement.evidenceIDs] as [String: Any]
             }] as [String: Any]
         }]
    }

    private func localReflectionObject() -> [String: Any] {
        let isChinese = preferredLanguage.hasPrefix("zh")
        let whatIDid = snapshot.blocks.sorted { $0.activeDurationMS > $1.activeDurationMS }
            .prefix(3).map { block in
                statementObject(
                    isChinese
                        ? "在「\(block.title)」上停留了 \(journalDuration(block.activeDurationMS, chinese: true))。"
                        : "Spent \(journalDuration(block.activeDurationMS, chinese: false)) with \(block.title).",
                    evidenceIDs: block.eventIDs)
            }
        let learning = snapshot.materials.prefix(4).map { material in
            statementObject(
                isChinese
                    ? "读到「\(material.title)」，前后停留了 \(journalDuration(material.durationMS, chinese: true))。"
                    : "Returned to \(material.title) for \(journalDuration(material.durationMS, chinese: false)).",
                evidenceIDs: material.eventIDs)
        }
        let openLoops = snapshot.blocks.filter { $0.revisitCount > 0 }
            .sorted { $0.revisitCount > $1.revisitCount }.prefix(2).map { block in
                statementObject(
                    isChinese
                        ? "几次回到「\(block.title)」，它也许还在心里。"
                        : "You returned to \(block.title) a few times; it may still be on your mind.",
                    evidenceIDs: block.eventIDs, kind: "inference")
            }
        let carry = snapshot.blocks.max { $0.activeDurationMS < $1.activeDurationMS }.map { block in
            [statementObject(
                isChinese
                    ? "如果明天还想继续，可以从「\(block.title)」接上。"
                    : "If you want to continue tomorrow, \(block.title) is a natural place to return.",
                evidenceIDs: block.eventIDs, kind: "inference")]
        } ?? []
        let values: [DailyReflectionSectionKind: [[String: Any]]] = [
            .whatIDid: Array(whatIDid), .timeAndAttention: [],
            .learning: Array(learning), .openLoops: Array(openLoops), .tomorrow: carry,
        ]
        return [
            "headline": reflection.headline, "summary": reflection.summary,
            "aiEnhanced": false,
            "sections": DailyReflectionSectionKind.allCases.map { kind in
                ["id": kind.rawValue, "statements": values[kind] ?? []] as [String: Any]
            },
        ]
    }

    private func statementObject(_ text: String, evidenceIDs: [String],
                                 kind: String = "fact") -> [String: Any] {
        ["text": text, "kind": kind, "evidenceIDs": evidenceIDs]
    }

    private func journalDuration(_ milliseconds: Double, chinese: Bool) -> String {
        let minutes = max(1, Int((milliseconds / 60_000).rounded()))
        if minutes < 60 { return chinese ? "\(minutes) 分钟" : "\(minutes) min" }
        let hours = minutes / 60, remainder = minutes % 60
        if remainder == 0 { return chinese ? "\(hours) 小时" : "\(hours)h" }
        return chinese ? "\(hours) 小时 \(remainder) 分" : "\(hours)h \(remainder)m"
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

    /// Follow Mimo's in-app bilingual choice instead of the Mac's primary
    /// locale, so Settings and Today Journal never disagree about language.
    private var preferredLanguage: String {
        voiceLanguage() == "en" ? "en-US" : "zh-CN"
    }

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
