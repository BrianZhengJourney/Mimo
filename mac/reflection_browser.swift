// Mimo Reflection Browser — native AppKit/WKWebView host.
//
// Security boundaries live here, not in reflection.html:
// - only the bundled main-frame file may use the `reflection` bridge;
// - Notion credentials are read and written exclusively through Keychain;
// - external navigation is denied (an explicit, allow-listed bridge action is
//   the only way to open a Notion page);
// - model calls require a native data-scope confirmation first.

import AppKit
import Foundation
import WebKit

final class ReflectionBrowserController: NSObject, NSWindowDelegate,
                                         WKNavigationDelegate,
                                         WKScriptMessageHandler {
    fileprivate static let stateVersion = ReflectionPersistedStateSchema.currentVersion
    private static let bridgeName = "reflection"

    private let root: URL
    private let browserRoot: URL
    private let stateURL: URL
    private let fixtureName: String?
    private let cache: NotionReflectionCache
    private let tokenStore: NotionTokenStore
    private let notionService: NotionReflectionService
    private let writebackExecutor: NotionWritebackExecutor

    private var reflectionModel: ReflectionModel?
    private var modelWasExplicitlySet = false
    private var state: ReflectionBrowserPersistedState
    private var activities: [ActivityEvent] = []
    private var reflections: [NotionReflection] = []
    private var evidence: [ReflectionEvidence] = []
    private var cachedSnapshot: NotionSyncSnapshot?
    private var syncStatus = "idle"
    private var syncMessage: String?
    private var syncError: String?
    private var activityStatus = "idle"
    private var activityMessage: String?
    private var activityError: String?
    private var analysisStatus = "idle"
    private var analysisMessage: String?
    private var analysisError: String?
    private var pageReady = false
    private var syncTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var writebackTask: Task<Void, Never>?
    private var syncGeneration = UUID()
    private var analysisGeneration = UUID()
    private var writebackGeneration = UUID()
    private var writebackConfirming = false
    private var activityGeneration = UUID()

    private(set) var window: NSWindow?
    private var webView: WKWebView?

    var isFixtureMode: Bool { fixtureName != nil }

    init(root: URL) {
        let fixture = Self.fixtureFromProcess()
        self.root = root
        fixtureName = fixture
        browserRoot = root.appendingPathComponent("ReflectionBrowser", isDirectory: true)
        stateURL = browserRoot.appendingPathComponent("reflection-state.json", isDirectory: false)
        let cache = NotionReflectionCache(
            fileURL: browserRoot.appendingPathComponent("notion-cache.json", isDirectory: false))
        self.cache = cache
        let tokenStore = KeychainNotionTokenStore()
        self.tokenStore = tokenStore
        let client = NotionHTTPClient(tokenStore: tokenStore,
                                      transport: EphemeralNotionTransport())
        notionService = NotionReflectionService(client: client, cache: cache)
        writebackExecutor = NotionWritebackExecutor(
            client: client,
            ledgerURL: browserRoot.appendingPathComponent("writeback-ledger.json", isDirectory: false))
        state = fixture == nil
            ? (Self.loadState(from: stateURL) ?? ReflectionBrowserPersistedState())
            : ReflectionBrowserPersistedState()
        reflectionModel = fixture == nil && MimoSecret.openAI.isConfigured
            ? OpenAIReflectionModel(keyReader: { MimoSecret.openAI.read() }) : nil
        super.init()
        // A preview is a confirmation-time artifact, not durable authority.
        // Rebuild it from the current synthesis/marks after every launch so a
        // stale preview can never bypass newer evidence-scope validation.
        state.writebackPreview = nil
        if fixture == nil { restoreCachedReflections() }
    }

    deinit {
        syncTask?.cancel()
        analysisTask?.cancel()
        writebackTask?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeName)
    }

    /// Test/host integration point. Production resolves the existing OpenAI
    /// Keychain configuration; passing nil exercises the browse-only state.
    func setModel(_ model: ReflectionModel?) {
        invalidateCurrentAnalysis()
        modelWasExplicitlySet = true
        reflectionModel = model
        pushState()
    }

    func present() {
        precondition(Thread.isMainThread, "ReflectionBrowserController.present() must run on the main thread")
        if fixtureName == nil, !modelWasExplicitlySet {
            reflectionModel = MimoSecret.openAI.isConfigured
                ? OpenAIReflectionModel(keyReader: { MimoSecret.openAI.read() }) : nil
        }
        if window == nil { buildWindow() }
        if fixtureName == nil {
            refreshActivities()
        }
        guard let window else { return }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Existing privacy controls notify the browser after activity erasure so
    /// derived conversations cannot outlive their deleted evidence. A full
    /// erase also drops the imported Notion cache, but keeps connection choices
    /// and Keychain credentials intact.
    @discardableResult
    func activityHistoryDidChange(removeNotionCache: Bool = false) -> Bool {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.activityHistoryDidChange() must run on the main thread")
        invalidateCurrentAnalysis()
        var cleared = true
        if removeNotionCache {
            cancelNotionSync()
            state.notionRefreshSuspended = true
            if FileManager.default.fileExists(atPath: cache.fileURL.path) {
                do { try FileManager.default.removeItem(at: cache.fileURL) }
                catch { cleared = false }
            }
            cachedSnapshot = nil
            reflections = []
            syncStatus = "idle"
            syncMessage = "Local Notion cache deleted. Sync manually to import it again."
            syncError = nil
        }
        cleared = persistState() && cleared
        if !cleared {
            syncStatus = "error"
            syncMessage = nil
            syncError = "Some Reflection Browser data could not be deleted from this Mac."
        }
        refreshActivities()
        rebuildEvidenceIfNeeded()
        pushState()
        return cleared
    }

    /// Retention changes are a privacy boundary. Invalidate derived output
    /// before the asynchronous re-read so a stale draft cannot be confirmed in
    /// the window between deleting raw evidence and rebuilding the index.
    func activityArchiveDidPrune() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.activityArchiveDidPrune() must run on the main thread")
        invalidateCurrentAnalysis()
        persistState()
        refreshActivities()
    }

    /// Loads cache immediately, then performs a launch refresh only when both a
    /// target and a Keychain token exist. The cache remains usable on failure.
    func refreshFromNotionIfConfigured() {
        precondition(Thread.isMainThread,
                     "ReflectionBrowserController.refreshFromNotionIfConfigured() must run on the main thread")
        guard fixtureName == nil else { return }
        restoreCachedReflections()
        guard state.target != nil else { pushState(); return }
        if state.notionRefreshSuspended == true {
            syncStatus = "idle"
            syncMessage = "Local Notion cache was cleared. Sync manually when you want to import it again."
            syncError = nil
            pushState()
            return
        }
        let tokenAvailable: Bool
        do { tokenAvailable = try notionTokenIsAvailable() }
        catch {
            syncStatus = "error"
            syncMessage = nil
            syncError = "Mimo could not read the Notion token from Keychain. Unlock this Mac and try again."
            pushState()
            return
        }
        guard tokenAvailable else {
            syncStatus = "idle"
            syncMessage = nil
            syncError = nil
            pushState()
            return
        }
        syncNotion(trigger: .launchRefresh)
    }

    // MARK: Window and navigation boundary

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: Self.bridgeName)
        if let fixtureName,
           let fixtureData = try? JSONEncoder().encode(fixtureName),
           let fixtureJSON = String(data: fixtureData, encoding: .utf8) {
            // WKWebView rejects file URLs containing a query string. Inject
            // the allowlisted offline fixture before the document runs while
            // keeping the actual load URL a plain bundled file URL.
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.__mimoReflectionFixture = \(fixtureJSON);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }

        let frame = NSRect(x: 0, y: 0, width: 1_260, height: 790)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true

        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = preferredLanguage.hasPrefix("zh") ? "Mimo · 深度回望" : "Mimo · Reflection Browser"
        window.minSize = NSSize(width: 980, height: 640)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.webView = webView
        self.window = window
        guard let resourceRoot = Bundle.main.resourceURL else {
            showNativeError("Reflection Browser resources are unavailable.")
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page posts `ready`; waiting for that bridge message also proves
        // its script has installed window.reflectionLoad.
    }

    private func isBundledResource(_ url: URL) -> Bool {
        guard url.isFileURL, let resourceRoot = Bundle.main.resourceURL else { return false }
        let rootPath = resourceRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func isTrustedBridgeFrame(_ message: WKScriptMessage) -> Bool {
        guard message.name == Self.bridgeName,
              message.frameInfo.isMainFrame,
              let webView, message.webView === webView,
              let url = message.frameInfo.request.url,
              isBundledResource(url),
              url.lastPathComponent == "reflection.html" else { return false }
        return true
    }

    // MARK: WK bridge

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
        case "setRange":
            setRange(body)
        case "sync":
            syncNotion(trigger: .manual)
        case "saveConnection":
            saveConnection(body)
        case "clearToken":
            clearToken()
        case "savePrivacy":
            savePrivacy(body)
        case "openExternal":
            if let raw = body["url"] as? String { openNotionURL(raw) }
        case "synthesize":
            beginSynthesis(body)
        case "saveMark":
            saveMark(body)
        case "removeMark":
            removeMark(body)
        case "previewWriteback":
            previewWriteback(body)
        case "confirmWriteback":
            confirmWriteback()
        case "cancelWriteback":
            guard !writebackConfirming else { return }
            state.writebackPreview = nil
            state.writebackError = nil
            persistState()
            pushState()
        default:
            break
        }
    }

    // MARK: Range and local activity

    private func setRange(_ body: [String: Any]) {
        let mode = (body["mode"] as? String ?? "today").lowercased()
        switch mode {
        case "week":
            state.rangeMode = "week"
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
        default:
            state.rangeMode = "today"
        }
        invalidateCurrentAnalysis()
        persistState()
        refreshActivities()
        filterCachedReflections()
        rebuildEvidenceIfNeeded()
        pushState()
    }

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
        let ignoredDomains = state.ignoredDomains.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }.filter { !$0.isEmpty }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ActivityJSONLParser.read(urls: urls, range: range)
            let visible = result.events.filter { event in
                let app = event.app.folding(options: [.caseInsensitive], locale: .current)
                guard !ignoredApps.contains(app) else { return false }
                guard let domain = event.domain?.lowercased() else { return true }
                return !ignoredDomains.contains { ignored in
                    domain == ignored || domain.hasSuffix("." + ignored)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.activityGeneration == generation else { return }
                self.activities = visible
                let malformedCount = result.malformedLineNumbers.count
                let unreadableCount = result.unreadableSourceIDs.count
                if !urls.isEmpty && unreadableCount == urls.count {
                    self.activityStatus = "error"
                    self.activityMessage = nil
                    self.activityError = "Mimo could not read the local activity archive."
                } else if malformedCount > 0 || unreadableCount > 0 {
                    self.activityStatus = "warning"
                    self.activityMessage = "Loaded available activity; skipped \(malformedCount) malformed line(s) and \(unreadableCount) unreadable file(s)."
                    self.activityError = nil
                } else {
                    self.activityStatus = "ready"
                    self.activityMessage = nil
                    self.activityError = nil
                }
                self.rebuildEvidenceIfNeeded()
                self.invalidateDerivedStateIfEvidenceMissing()
                self.pushState()
            }
        }
    }

    private func activityLogURLs() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("activity-") && name.hasSuffix(".jsonl")
        }
    }

    // MARK: Notion cache and sync

    private var hasNotionToken: Bool {
        (try? notionTokenIsAvailable()) == true
    }

    private func notionTokenIsAvailable() throws -> Bool {
        try tokenStore.readToken()?.isEmpty == false
    }

    private func restoreCachedReflections() {
        guard let target = state.target, let snapshot = cache.load(for: target) else {
            cachedSnapshot = nil
            reflections = []
            rebuildEvidenceIfNeeded()
            return
        }
        cachedSnapshot = snapshot
        filterCachedReflections()
        rebuildEvidenceIfNeeded()
    }

    private func filterCachedReflections() {
        guard let snapshot = cachedSnapshot else { reflections = []; return }
        let range = currentRange
        reflections = snapshot.reflectionModels.filter { reflection in
            guard let date = reflection.reflectionDate else { return true }
            return date >= range.start && date < range.end
        }
    }

    private func syncNotion(trigger: NotionSyncTrigger) {
        guard let target = state.target else {
            syncStatus = "error"
            syncError = "Connect a Notion page or database before syncing."
            pushState()
            return
        }
        let tokenAvailable: Bool
        do { tokenAvailable = try notionTokenIsAvailable() }
        catch {
            syncStatus = "error"
            syncMessage = nil
            syncError = "Mimo could not read the Notion token from Keychain. Unlock this Mac and try again."
            pushState()
            return
        }
        guard tokenAvailable else {
            syncStatus = "idle"
            syncError = nil
            syncMessage = "Notion is not connected"
            pushState()
            return
        }
        guard syncTask == nil else { return }
        if trigger == .manual, state.notionRefreshSuspended == true {
            state.notionRefreshSuspended = false
            persistState()
        }
        let generation = UUID()
        syncGeneration = generation
        syncStatus = "syncing"
        syncMessage = nil
        syncError = nil
        pushState()
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.notionService.sync(
                    target: target, trigger: trigger, persist: false)
                await MainActor.run {
                    guard self.syncGeneration == generation,
                          self.state.target == target,
                          !Task.isCancelled else { return }
                    do { try self.cache.save(snapshot) }
                    catch {
                        self.syncStatus = "error"
                        self.syncMessage = nil
                        self.syncError = "Mimo could not save the Notion cache on this Mac."
                        self.syncTask = nil
                        self.pushState()
                        return
                    }
                    let contentChanged = Self.contentSignature(self.cachedSnapshot)
                        != Self.contentSignature(snapshot)
                    if contentChanged { self.invalidateCurrentAnalysis() }
                    self.cachedSnapshot = snapshot
                    self.filterCachedReflections()
                    self.syncStatus = "synced"
                    self.syncMessage = "Synced"
                    self.syncError = nil
                    self.syncTask = nil
                    self.rebuildEvidenceIfNeeded()
                    self.pushState()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Mimo could not sync Notion. Cached reflections remain available."
                await MainActor.run {
                    guard self.syncGeneration == generation,
                          self.state.target == target,
                          !Task.isCancelled else { return }
                    self.syncStatus = "error"
                    self.syncMessage = nil
                    self.syncError = message
                    self.syncTask = nil
                    self.pushState()
                }
            }
        }
    }

    private func saveConnection(_ body: [String: Any]) {
        guard let targetRaw = body["targetURL"] as? String else { return }
        do {
            let hint: NotionTargetKind?
            switch body["targetKind"] as? String ?? "auto" {
            case "auto", "": hint = nil
            case "page": hint = .page
            case "database": hint = .database
            case "dataSource": hint = .dataSource
            default: throw NotionBackendError.invalidTarget
            }
            let target = try NotionTargetParser.parse(targetRaw, hint: hint)
            let token = (body["token"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { try tokenStore.saveToken(token) }
            else if try !notionTokenIsAvailable() { throw NotionBackendError.missingToken }
            cancelNotionSync()
            if state.target != target { invalidateCurrentAnalysis() }
            state.target = target
            state.targetURL = Self.canonicalTargetURL(target)
            state.notionRefreshSuspended = false
            cachedSnapshot = cache.load(for: target)
            filterCachedReflections()
            guard persistState() else {
                syncStatus = "error"
                syncMessage = nil
                syncError = "Mimo could not save this Notion connection on this Mac."
                pushState()
                return
            }
            syncNotion(trigger: .manual)
        } catch {
            syncStatus = "error"
            syncError = (error as? LocalizedError)?.errorDescription
                ?? "The Notion connection could not be saved."
            pushState()
        }
    }

    private func clearToken() {
        cancelNotionSync()
        do {
            try tokenStore.clearToken()
            syncStatus = "idle"
            syncMessage = "Notion token removed; cached reflections are still available."
            syncError = nil
        } catch {
            syncStatus = "error"
            syncError = "The Notion token could not be removed from Keychain."
        }
        pushState()
    }

    private func cancelNotionSync() {
        syncGeneration = UUID()
        syncTask?.cancel()
        syncTask = nil
    }

    private func savePrivacy(_ body: [String: Any]) {
        func clean(_ value: Any?) -> [String] {
            let raw = value as? [String] ?? []
            var seen = Set<String>()
            let cleaned: [String] = raw.compactMap { item in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
                return seen.insert(trimmed.lowercased()).inserted ? trimmed : nil
            }
            return Array(cleaned.prefix(200))
        }
        state.ignoredApps = clean(body["ignoredApps"])
        state.ignoredDomains = clean(body["ignoredDomains"]).map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        invalidateCurrentAnalysis()
        persistState()
        refreshActivities()
        pushState()
    }

    private func openNotionURL(_ raw: String) {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased(),
              host == "notion.so" || host.hasSuffix(".notion.so")
                || host == "notion.site" || host.hasSuffix(".notion.site")
                || host == "notion.com" || host.hasSuffix(".notion.com"),
              let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Model and conversation

    private func rebuildEvidenceIfNeeded() {
        let local = LocalReflectionSynthesizer.build(events: activities, reflections: reflections)
        evidence = local.evidence
    }

    private var availableEvidence: [ReflectionEvidence] {
        evidence
    }

    private func invalidateCurrentAnalysis() {
        analysisGeneration = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        writebackGeneration = UUID()
        writebackTask?.cancel()
        writebackTask = nil
        writebackConfirming = false
        analysisStatus = "idle"
        analysisMessage = nil
        analysisError = nil
        state.synthesis = nil
        state.synthesisDraft = nil
        state.writebackPreview = nil
        state.writebackError = nil
        state.marks = []
        state.conversation = ReflectionConversation(
            id: "reflection-main", title: "Mimo Reflection Browser")
    }

    private func invalidateDerivedStateIfEvidenceMissing() {
        let currentIDs = Set(evidence.map(\.id))
        let synthesisIDs = Set(state.synthesis?.sections
            .flatMap(\.statements).flatMap(\.evidenceIDs) ?? [])
        let conversationIDs = Set(state.conversation.messages.flatMap(\.evidenceIDs))
        let draftIDs = Set(state.synthesisDraft?.evidenceIDs ?? [])
        let referenced = synthesisIDs.union(conversationIDs).union(draftIDs)
        guard !referenced.isSubset(of: currentIDs) else { return }
        invalidateCurrentAnalysis()
        persistState()
    }

    private func beginSynthesis(_ body: [String: Any]) {
        guard analysisTask == nil else { return }
        guard let model = reflectionModel else {
            analysisStatus = "error"
            analysisMessage = nil
            analysisError = ReflectionModelError.missingKey.errorDescription
            pushState()
            return
        }
        let requested = body["selectedEvidenceIDs"] as? [String] ?? []
        let selected = normalizeEvidenceIDs(requested)
        guard !selected.isEmpty else {
            analysisStatus = "error"
            analysisMessage = nil
            analysisError = ReflectionModelError.noEvidence.errorDescription
            pushState()
            return
        }
        let selectedEvidence = availableEvidence.filter { selected.contains($0.id) }
        let selectedActivityIDs = Set(selectedEvidence.filter { $0.sourceKind == .activity }.map(\.sourceID))
        let selectedReflectionIDs = Set(selectedEvidence.filter { $0.sourceKind == .notion }.map(\.sourceID))
        let selectedActivities = activities.filter { selectedActivityIDs.contains($0.id) }
        let selectedReflections = reflections.filter { selectedReflectionIDs.contains($0.id) }
        let selectedSet = Set(selected)
        let conversationHistory = state.conversation.messages.filter { message in
            !message.evidenceIDs.isEmpty
                && message.evidenceIDs.allSatisfy(selectedSet.contains)
        }

        guard confirmModelScope(eventCount: selectedActivities.count,
                                reflectionCount: selectedReflections.count,
                                evidenceCount: selectedEvidence.count,
                                conversationCount: conversationHistory.count) else { return }

        let prompt = (body["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            state.conversation.messages.append(.init(
                id: "user-\(UUID().uuidString.lowercased())", role: .user,
                content: String(prompt.prefix(8_000)), evidenceIDs: selected))
            state.conversation.updatedAt = Date()
            persistState()
        }
        let generation = UUID()
        analysisGeneration = generation
        analysisStatus = "loading"
        analysisMessage = "Building evidence-linked synthesis…"
        analysisError = nil
        pushState()
        let safeActivities = selectedActivities.map { $0.modelSafeCopy() }
        let safeReflections = selectedReflections.map { item -> NotionReflection in
            var copy = item
            copy.pageURL = SensitiveURLScrubber.scrub(copy.pageURL)
            return copy
        }
        let safeEvidence = selectedEvidence.map { item -> ReflectionEvidence in
            var copy = item
            copy.sourceURL = copy.sourceURL.map(SensitiveURLScrubber.scrub)
            return copy
        }
        let input = ReflectionModelInput(dateRange: currentRange,
                                         activities: safeActivities,
                                         reflections: safeReflections,
                                         evidence: safeEvidence,
                                         chosenEvidenceIDs: selected,
                                         prompt: prompt.isEmpty ? nil : prompt,
                                         conversation: conversationHistory)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let synthesis = try await model.synthesize(input)
                await MainActor.run {
                    guard self.analysisGeneration == generation,
                          !Task.isCancelled else { return }
                    self.acceptSynthesis(synthesis)
                    self.analysisStatus = "ready"
                    self.analysisMessage = "Synthesis ready"
                    self.analysisError = nil
                    self.analysisTask = nil
                    self.persistState()
                    self.pushState()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "The model could not build a synthesis."
                await MainActor.run {
                    guard self.analysisGeneration == generation,
                          !Task.isCancelled else { return }
                    self.analysisStatus = "error"
                    self.analysisMessage = nil
                    self.analysisError = message
                    self.analysisTask = nil
                    self.persistState()
                    self.pushState()
                }
            }
        }
    }

    private func normalizeEvidenceIDs(_ requested: [String]) -> [String] {
        var evidenceByID: [String: ReflectionEvidence] = [:]
        for item in availableEvidence where evidenceByID[item.id] == nil {
            evidenceByID[item.id] = item
        }
        let bySource = Dictionary(grouping: availableEvidence, by: \.sourceID)
        var output: [String] = []
        for raw in requested {
            if evidenceByID[raw] != nil, !output.contains(raw) { output.append(raw) }
            else if let match = bySource[raw]?.first, !output.contains(match.id) { output.append(match.id) }
        }
        return output
    }

    private func confirmModelScope(eventCount: Int, reflectionCount: Int,
                                   evidenceCount: Int, conversationCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = preferredLanguage.hasPrefix("zh") ? "确认本次回望范围" : "Confirm reflection scope"
        let range = currentRange
        let rangeText = "\(Self.dayFormatter.string(from: range.start)) → \(Self.dayFormatter.string(from: range.end.addingTimeInterval(-1)))"
        if preferredLanguage.hasPrefix("zh") {
            let destination = reflectionModel is OpenAIReflectionModel
                ? "这些明确选中的资料会发送给 OpenAI。" : "分析仅在本机完成。"
            alert.informativeText = "日期范围：\(rangeText)\n\n将分析 \(eventCount) 条活动、\(reflectionCount) 篇手记、\(evidenceCount) 条证据，并带入 \(conversationCount) 条同范围对话。活动 URL 的敏感查询参数和片段会先清洗；未选择的本地记录不会进入模型。\(destination)"
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
        } else {
            let destination = reflectionModel is OpenAIReflectionModel
                ? "The explicitly selected material will be sent to OpenAI."
                : "Analysis stays entirely on this Mac."
            alert.informativeText = "Date range: \(rangeText)\n\nAnalyze \(eventCount) activities, \(reflectionCount) reflections, and \(evidenceCount) evidence items, with \(conversationCount) same-scope dialogue messages. Sensitive URL query values and fragments are scrubbed first; unselected local records are excluded. \(destination)"
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func acceptSynthesis(_ synthesis: LocalReflectionSynthesis) {
        let synthesisEvidenceIDs = Self.uniqueEvidenceIDs(synthesis.evidence.map(\.id))
        let carriedHighlights = highlightedExcerpts(
            allowedEvidenceIDs: synthesisEvidenceIDs)
        remapCurrentMarksToConversation()
        state.synthesis = synthesis
        var markdown = Self.synthesisMarkdown(synthesis)
        if !carriedHighlights.isEmpty {
            markdown += "\n\n## Marked for synthesis\n\n"
                + carriedHighlights.map { "- \($0.text)" }.joined(separator: "\n")
        }
        let assistantEvidence = Self.uniqueEvidenceIDs(
            synthesis.sections.flatMap(\.statements).flatMap(\.evidenceIDs)
                + carriedHighlights.flatMap(\.evidenceIDs))
        state.conversation.messages.append(.init(
            id: "assistant-\(UUID().uuidString.lowercased())", role: .assistant,
            content: markdown, evidenceIDs: assistantEvidence))
        state.conversation.updatedAt = Date()
        let selectedNotionPageIDs = Set(synthesis.evidence
            .filter { $0.sourceKind == .notion }
            .compactMap { selected in
                reflections.first(where: { $0.id == selected.sourceID })?.pageID
            })
        let targetID: String?
        if selectedNotionPageIDs.count == 1 {
            targetID = selectedNotionPageIDs.first
        } else if selectedNotionPageIDs.isEmpty, state.target?.kind == .page {
            targetID = state.target?.id
        } else {
            // Never pick an arbitrary first row from a database/data source.
            // The preview requires the user to choose a named destination.
            targetID = nil
        }
        let fingerprint = "\(currentRange.start.timeIntervalSince1970)|\(currentRange.end.timeIntervalSince1970)|\(markdown)|\(targetID ?? "")"
        let draftID = "synthesis-\(Self.stableHash(fingerprint))"
        state.synthesisDraft = SynthesisDraft(
            id: draftID, dateRange: currentRange, title: "Mimo Synthesis",
            markdown: markdown,
            evidenceIDs: Self.uniqueEvidenceIDs(
                synthesisEvidenceIDs + carriedHighlights.flatMap(\.evidenceIDs)),
            target: .appendPage, targetPageID: targetID,
            idempotencyKey: Self.stableHash("\(draftID)|\(markdown)|\(targetID ?? "")"))
        state.writebackPreview = nil
        state.writebackError = nil
    }

    // MARK: Marks

    private func saveMark(_ body: [String: Any]) {
        guard let raw = body["mark"] as? [String: Any],
              let id = raw["id"] as? String,
              let kindRaw = raw["kind"] as? String,
              let kind = ReflectionMarkKind(rawValue: kindRaw),
              let text = raw["text"] as? String,
              let responseID = raw["responseID"] as? String,
              !id.isEmpty, !text.isEmpty, !responseID.isEmpty,
              let source = markSourceText(id: responseID),
              let offsets = ReflectionTextRangeResolver.characterOffsets(
                in: source, selectedText: text,
                utf16Location: (raw["locationUTF16"] as? NSNumber)?.intValue,
                utf16Length: (raw["lengthUTF16"] as? NSNumber)?.intValue) else { return }
        let mark = ReflectionMark(id: String(id.prefix(200)),
                                  conversationID: state.conversation.id,
                                  messageID: responseID, kind: kind,
                                  location: offsets.location,
                                  length: offsets.length, text: text,
                                  evidenceIDs: evidenceIDs(forSourceID: responseID))
        state.marks.removeAll { $0.id == mark.id }
        state.marks.append(mark)
        persistState()
        pushState()
    }

    private func removeMark(_ body: [String: Any]) {
        guard let id = body["id"] as? String else { return }
        state.marks.removeAll { $0.id == id }
        persistState()
        pushState()
    }

    private func currentClaimText(id: String) -> String? {
        guard let synthesis = state.synthesis else { return nil }
        for section in synthesis.sections {
            for (offset, statement) in section.statements.enumerated()
            where Self.claimID(section: section.kind, offset: offset, text: statement.text) == id {
                return statement.text
            }
        }
        return nil
    }

    private func markSourceText(id: String) -> String? {
        currentClaimText(id: id)
            ?? state.conversation.messages.first(where: { $0.id == id })?.content
    }

    private func evidenceIDs(forSourceID sourceID: String) -> [String] {
        if let synthesis = state.synthesis {
            for section in synthesis.sections {
                for (offset, statement) in section.statements.enumerated()
                where Self.claimID(section: section.kind, offset: offset,
                                   text: statement.text) == sourceID {
                    return statement.evidenceIDs
                }
            }
        }
        return state.conversation.messages.first(where: { $0.id == sourceID })?
            .evidenceIDs ?? []
    }

    private func evidenceIDs(for mark: ReflectionMark) -> [String] {
        if let bound = mark.evidenceIDs, !bound.isEmpty {
            return Self.uniqueEvidenceIDs(bound)
        }
        return evidenceIDs(forSourceID: mark.messageID)
    }

    private func text(for mark: ReflectionMark) -> String? {
        guard let source = markSourceText(id: mark.messageID) else { return nil }
        if let range = ReflectionTextRangeResolver.characterRange(
            in: source, location: mark.location, length: mark.length) {
            let selected = String(source[range])
            if mark.text == nil || mark.text == selected { return selected }
        }
        // Backward compatibility for old persisted marks that predate exact
        // offsets. Refuse an ambiguous repeated phrase instead of moving it.
        guard let saved = mark.text,
              let offsets = ReflectionTextRangeResolver.characterOffsets(
                in: source, selectedText: saved,
                utf16Location: nil, utf16Length: nil),
              ReflectionTextRangeResolver.characterRange(
                in: source, location: offsets.location,
                length: offsets.length) != nil else { return nil }
        return saved
    }

    private func remapCurrentMarksToConversation() {
        guard let assistant = state.conversation.messages.last(where: { $0.role == .assistant }) else {
            return
        }
        let claimRanges = currentClaimRanges(in: assistant.content)
        for index in state.marks.indices {
            let claimID = state.marks[index].messageID
            let sourceEvidenceIDs = evidenceIDs(for: state.marks[index])
            guard let claimText = currentClaimText(id: claimID),
                  let claimRange = claimRanges[claimID],
                  let localRange = ReflectionTextRangeResolver.characterRange(
                    in: claimText, location: state.marks[index].location,
                    length: state.marks[index].length) else { continue }
            let relativeStart = claimText.distance(
                from: claimText.startIndex, to: localRange.lowerBound)
            let relativeEnd = claimText.distance(
                from: claimText.startIndex, to: localRange.upperBound)
            guard let start = assistant.content.index(
                    claimRange.lowerBound, offsetBy: relativeStart,
                    limitedBy: claimRange.upperBound),
                  let end = assistant.content.index(
                    claimRange.lowerBound, offsetBy: relativeEnd,
                    limitedBy: claimRange.upperBound) else { continue }
            let selected = String(assistant.content[start..<end])
            state.marks[index].messageID = assistant.id
            state.marks[index].location = assistant.content.distance(
                from: assistant.content.startIndex, to: start)
            state.marks[index].length = assistant.content.distance(
                from: start, to: end)
            state.marks[index].text = selected
            state.marks[index].evidenceIDs = sourceEvidenceIDs
        }
    }

    private func currentClaimRanges(in markdown: String)
        -> [String: Range<String.Index>] {
        guard let synthesis = state.synthesis else { return [:] }
        var output: [String: Range<String.Index>] = [:]
        var cursor = markdown.startIndex
        for section in synthesis.sections {
            let heading = "### \(section.kind.rawValue)"
            if let headingRange = markdown.range(of: heading,
                                                 range: cursor..<markdown.endIndex) {
                cursor = headingRange.upperBound
            }
            for (offset, statement) in section.statements.enumerated() {
                guard let range = markdown.range(of: statement.text,
                                                 range: cursor..<markdown.endIndex) else {
                    continue
                }
                output[Self.claimID(section: section.kind, offset: offset,
                                    text: statement.text)] = range
                cursor = range.upperBound
            }
        }
        return output
    }

    // MARK: Explicit writeback

    private func previewWriteback(_ body: [String: Any]) {
        guard activityStatus != "loading" else {
            state.writebackError = "Activity evidence is refreshing. Preview again when it finishes."
            pushState()
            return
        }
        guard var draft = state.synthesisDraft, let synthesis = state.synthesis else {
            state.writebackError = "Create a synthesis before previewing writeback."
            pushState()
            return
        }
        let requestedID = (body["targetID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedID, !requestedID.isEmpty,
           let normalized = NotionTargetParser.normalizeID(requestedID) {
            let allowedPageIDs = Set(reflections.map(\.pageID)
                + (state.target?.kind == .page ? [state.target!.id] : []))
            if allowedPageIDs.contains(normalized) { draft.targetPageID = normalized }
        }
        // MVP writeback is append-only. A database/data-source container is
        // never a writable page, and child-page creation is postponed until it
        // has a durable remote idempotency lookup.
        draft.target = .appendPage
        let synthesisEvidenceIDs = Self.uniqueEvidenceIDs(synthesis.evidence.map(\.id))
        let scopedHighlights = highlightedExcerpts(
            allowedEvidenceIDs: synthesisEvidenceIDs)
        draft.markdown = Self.synthesisMarkdown(synthesis)
        if !scopedHighlights.isEmpty {
            draft.markdown += "\n\n## Marked for synthesis\n\n"
                + scopedHighlights.map { "- \($0.text)" }.joined(separator: "\n")
        }
        draft.evidenceIDs = Self.uniqueEvidenceIDs(
            synthesisEvidenceIDs + scopedHighlights.flatMap(\.evidenceIDs))
        draft.confirmedAt = nil
        do {
            let allowedPageIDs = Set(reflections.map(\.pageID)
                + (state.target?.kind == .page ? [state.target!.id] : []))
            guard let pageID = draft.targetPageID,
                  allowedPageIDs.contains(pageID) else {
                throw NotionBackendError.invalidTarget
            }
            state.synthesisDraft = draft
            var previewDraft = draft
            let evidenceLinks = writebackEvidenceLinks(for: previewDraft.evidenceIDs)
            if !evidenceLinks.isEmpty {
                previewDraft.markdown += "\n\n## Evidence Links\n\n" + evidenceLinks
            }
            let highlights = scopedHighlights.map(\.text).filter {
                !previewDraft.markdown.contains("- \($0)")
            }
            if !highlights.isEmpty {
                previewDraft.markdown += "\n\n## Marked for synthesis\n\n"
                    + highlights.map { "- \($0)" }.joined(separator: "\n")
            }
            state.writebackPreview = try NotionWritebackPreviewBuilder.build(
                draft: previewDraft, source: "Mimo local activity + selected Notion reflections")
            state.writebackError = nil
            if !persistState() {
                state.writebackError = "This preview is only in memory because Mimo could not save its recovery state. Keep this window open."
            }
            pushState()
        } catch {
            state.writebackError = (error as? LocalizedError)?.errorDescription
                ?? "The writeback preview could not be prepared."
            if !persistState() {
                state.writebackError = (state.writebackError ?? "")
                    + " The draft remains in memory only; keep this window open."
            }
            pushState()
        }
    }

    private func confirmWriteback() {
        guard let preview = state.writebackPreview,
              activityStatus != "loading",
              writebackTask == nil, !writebackConfirming else { return }
        let generation = UUID()
        writebackGeneration = generation
        writebackConfirming = true
        syncStatus = "syncing"
        syncMessage = "Writing confirmed synthesis to Notion…"
        syncError = nil
        pushState()
        writebackTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.writebackExecutor.execute(preview, confirmed: true)
            await MainActor.run {
                guard self.writebackGeneration == generation,
                      !Task.isCancelled else { return }
                self.writebackConfirming = false
                self.writebackTask = nil
                switch outcome {
                case .written:
                    self.syncStatus = "synced"
                    self.syncMessage = "Synthesis written to Notion"
                    self.syncError = nil
                    self.state.writebackError = nil
                    self.state.synthesisDraft?.confirmedAt = Date()
                case .alreadyWritten:
                    self.syncStatus = "synced"
                    self.syncMessage = "This synthesis was already written"
                    self.syncError = nil
                    self.state.writebackError = nil
                case .inProgress:
                    self.syncStatus = "syncing"
                    self.syncMessage = "This writeback is already in progress"
                    self.syncError = nil
                case .failed(_, let error):
                    self.syncStatus = "error"
                    self.syncMessage = nil
                    self.syncError = error.errorDescription
                    self.state.writebackError = error.errorDescription
                case .confirmationRequired:
                    self.syncStatus = "error"
                    self.syncMessage = nil
                    self.syncError = NotionBackendError.confirmationRequired.errorDescription
                    self.state.writebackError = NotionBackendError.confirmationRequired.errorDescription
                }
                // Preview and synthesis draft intentionally survive failures.
                if !self.persistState() {
                    let warning = "Mimo could not save the local writeback recovery state. Keep this window open; the current draft remains in memory."
                    self.syncStatus = "error"
                    self.syncMessage = nil
                    self.syncError = warning
                    self.state.writebackError = [self.state.writebackError, warning]
                        .compactMap { $0 }.joined(separator: " ")
                }
                self.pushState()
            }
        }
    }

    // MARK: HTML projection

    private func pushState() {
        guard pageReady, let webView else { return }
        let payload = htmlPayload()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.reflectionLoad(\(json))", completionHandler: nil)
    }

    private func htmlPayload() -> [String: Any] {
        let range = currentRange
        let aggregates = ActivityAggregator.aggregate(activities)
        let currentEvidence = availableEvidence
        var payload: [String: Any] = [
            "config": [
                "language": preferredLanguage,
                "modelConfigured": reflectionModel != nil,
                "modelStatus": reflectionModel == nil ? "missing"
                    : (reflectionModel is OpenAIReflectionModel ? "openai" : "local"),
                "fixture": false,
                "ignoredApps": state.ignoredApps,
                "ignoredDomains": state.ignoredDomains,
            ],
            "range": [
                "mode": state.rangeMode,
                "start": Self.dayFormatter.string(from: range.start),
                "end": Self.dayFormatter.string(from: range.end.addingTimeInterval(-1)),
            ],
            "activities": activities.map(Self.activityObject),
            "activityGroups": aggregates.map { aggregate in
                [
                    "id": aggregate.id,
                    "title": aggregate.label,
                    "category": aggregate.category,
                    "durationSeconds": aggregate.durationMS / 1_000,
                    "revisits": aggregate.revisitCount,
                    "contextSwitches": aggregate.contextSwitchCount,
                    // Raw events are embedded deliberately: aggregation is a
                    // view and never replaces source evidence.
                    "events": aggregate.expanded(using: activities).map(Self.activityObject),
                ] as [String: Any]
            },
            "reflections": reflections.map(Self.reflectionObject),
            "evidences": currentEvidence.map(Self.evidenceObject),
            "conversation": state.conversation.messages.map(Self.messageObject),
            "syncState": syncStateObject(),
            "analysisState": analysisStateObject(),
            "marks": markObjects(),
            "writebackTargets": writebackTargetsObject(),
        ]
        if let suggested = state.synthesisDraft?.targetPageID {
            payload["writebackSuggestedTargetID"] = suggested
        }
        if let synthesis = state.synthesis { payload["synthesis"] = synthesisObject(synthesis) }
        if let preview = state.writebackPreview {
            payload["writebackDraft"] = writebackObject(preview, error: state.writebackError)
        } else if let error = state.writebackError {
            payload["writebackDraft"] = ["error": error]
        }
        return payload
    }

    private func syncStateObject() -> [String: Any] {
        var output: [String: Any] = [
            "status": syncStatus,
            "hasToken": hasNotionToken,
            "activityStatus": activityStatus,
        ]
        if let message = syncMessage { output["message"] = message }
        if let error = syncError { output["error"] = error }
        if let message = activityMessage { output["activityMessage"] = message }
        if let error = activityError { output["activityError"] = error }
        if let target = state.target {
            output["targetID"] = target.id
            output["targetKind"] = target.kind.rawValue
        }
        if let url = state.targetURL { output["targetURL"] = url }
        if let date = cachedSnapshot?.syncedAt { output["lastSyncedAt"] = Self.timestamp(date) }
        return output
    }

    private func analysisStateObject() -> [String: Any] {
        var output: [String: Any] = ["status": analysisStatus]
        if let message = analysisMessage { output["message"] = message }
        if let error = analysisError { output["error"] = error }
        return output
    }

    private func synthesisObject(_ synthesis: LocalReflectionSynthesis) -> [String: Any] {
        ["sections": synthesis.sections.map { section in
            [
                "title": section.kind.rawValue,
                "claims": section.statements.enumerated().map { offset, statement in
                    [
                        "id": Self.claimID(section: section.kind, offset: offset,
                                           text: statement.text),
                        "kind": statement.claimKind.rawValue,
                        "text": statement.text,
                        "evidenceIDs": statement.evidenceIDs,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }]
    }

    private func markObjects() -> [[String: Any]] {
        state.marks.compactMap { mark in
            guard let selected = text(for: mark), !selected.isEmpty,
                  let source = markSourceText(id: mark.messageID) else { return nil }
            var output: [String: Any] = [
                "id": mark.id,
                "kind": mark.kind.rawValue,
                "text": selected,
                "responseID": mark.messageID,
                "createdAt": Self.timestamp(mark.createdAt),
            ]
            if let range = ReflectionTextRangeResolver.utf16Range(
                in: source, location: mark.location, length: mark.length) {
                output["locationUTF16"] = range.location
                output["lengthUTF16"] = range.length
            }
            output["evidenceIDs"] = evidenceIDs(for: mark)
            return output
        }
    }

    private func highlightedExcerpts(allowedEvidenceIDs: [String])
        -> [ReflectionMarkedExcerpt] {
        let candidates = state.marks.compactMap { mark -> ReflectionMarkedExcerpt? in
            guard mark.kind == .highlight,
                  let selected = text(for: mark)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selected.isEmpty else { return nil }
            return ReflectionMarkedExcerpt(
                text: selected, evidenceIDs: evidenceIDs(for: mark))
        }
        return ReflectionMarkScope.retained(
            candidates, allowedEvidenceIDs: allowedEvidenceIDs)
    }

    private func writebackObject(_ preview: NotionWritebackPreview,
                                 error: String?) -> [String: Any] {
        let mode: String
        let targetID: String
        switch preview.destination {
        case .appendToPage(let id): mode = "Append “Mimo Synthesis”"; targetID = id
        case .createPage(let id, _): mode = "Create child page"; targetID = id
        }
        var output: [String: Any] = [
            "targetMode": mode,
            "targetID": targetID,
            "dateRange": preview.dateRange,
            "dataScope": writebackDataScope(preview),
            "sources": ["Mimo local activity", "Notion reflections"],
            "evidenceIDs": preview.evidenceIDs,
            "idempotencyKey": preview.idempotencyKey,
            "markdown": preview.markdown,
            "confirming": writebackConfirming,
        ]
        if let target = writebackTargetsObject().first(where: {
            ($0["id"] as? String) == targetID
        }) {
            output["targetTitle"] = target["title"]
            output["targetURL"] = target["url"]
        }
        if let error { output["error"] = error }
        return output
    }

    private func writebackTargetsObject() -> [[String: Any]] {
        var output: [[String: Any]] = []
        var seen = Set<String>()
        for item in reflections where seen.insert(item.pageID).inserted {
            output.append([
                "id": item.pageID,
                "title": item.title,
                "url": item.pageURL,
            ])
        }
        if let target = state.target, target.kind == .page,
           seen.insert(target.id).inserted {
            output.append([
                "id": target.id,
                "title": preferredLanguage.hasPrefix("zh") ? "已连接的 Notion 页面" : "Connected Notion page",
                "url": state.targetURL ?? "https://www.notion.so/\(target.id.replacingOccurrences(of: "-", with: ""))",
            ])
        }
        return output
    }

    private func writebackDataScope(_ preview: NotionWritebackPreview) -> String {
        let chosen = Set(preview.evidenceIDs)
        let selected = availableEvidence.filter { chosen.contains($0.id) }
        let activityCount = selected.filter { $0.sourceKind == .activity }.count
        let reflectionCount = selected.filter { $0.sourceKind == .notion }.count
        return "\(activityCount) selected local events + \(reflectionCount) selected Notion reflections; model URLs scrubbed"
    }

    private func writebackEvidenceLinks(for evidenceIDs: [String]) -> String {
        let chosen = Set(evidenceIDs)
        return availableEvidence.filter { chosen.contains($0.id) }.map { item in
            let label = "\(item.id) · \(item.label)"
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "\n", with: " ")
            if item.sourceKind == .notion,
               let raw = item.sourceURL.map(SensitiveURLScrubber.scrub),
               let components = URLComponents(string: raw),
               components.scheme?.lowercased() == "https",
               let host = components.host?.lowercased(),
               host == "notion.so" || host.hasSuffix(".notion.so")
                    || host == "notion.site" || host.hasSuffix(".notion.site")
                    || host == "notion.com" || host.hasSuffix(".notion.com"),
               let url = components.url {
                return "- [\(label)](\(url.absoluteString))"
            }
            let when = item.timestampMS.map {
                " · \(Self.timestamp(Date(timeIntervalSince1970: $0 / 1_000)))"
            } ?? ""
            return "- \(label)\(when) · Mimo local activity"
        }.joined(separator: "\n")
    }

    @discardableResult
    private func persistState() -> Bool {
        do {
            try FileManager.default.createDirectory(at: browserRoot,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
            return true
        } catch {
            // Never log state contents: conversation text and URLs are private.
            return false
        }
    }

    private static func loadState(from url: URL) -> ReflectionBrowserPersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(
            ReflectionBrowserPersistedState.self, from: data) else { return nil }
        if decoded.version == stateVersion { return decoded }
        guard ReflectionPersistedStateSchema.requiresDerivedReset(
            from: decoded.version) else { return nil }
        var migrated = decoded
        migrated.version = stateVersion
        ReflectionPersistedStateSchema.resetDerivedState(
            marks: &migrated.marks,
            conversation: &migrated.conversation,
            synthesis: &migrated.synthesis,
            draft: &migrated.synthesisDraft)
        migrated.writebackPreview = nil
        migrated.writebackError = nil
        return migrated
    }

    // MARK: Pure projections and stable IDs

    private static func activityObject(_ event: ActivityEvent) -> [String: Any] {
        var output: [String: Any] = [
            "id": event.id,
            "start": timestamp(Date(timeIntervalSince1970: event.startedAtMS / 1_000)),
            "end": timestamp(Date(timeIntervalSince1970: event.endedAtMS / 1_000)),
            "durationSeconds": event.durationMS / 1_000,
            "app": event.app,
            "category": event.category,
            "order": event.order + 1,
            "revisits": event.isRevisit ? 1 : 0,
            "contextSwitches": event.isContextSwitch ? 1 : 0,
        ]
        if let title = event.title { output["title"] = title }
        if let url = event.fullURL { output["fullURL"] = url }
        if let domain = event.domain { output["domain"] = domain }
        if let canonical = event.canonicalLabel { output["canonical"] = canonical }
        return output
    }

    private static func reflectionObject(_ reflection: NotionReflection) -> [String: Any] {
        var output: [String: Any] = [
            "id": reflection.id,
            "title": reflection.title,
            "type": reflection.reflectionType.rawValue.capitalized,
            "markdown": reflection.markdown,
            "pageID": reflection.pageID,
            "url": reflection.pageURL,
            "syncedAt": timestamp(reflection.syncedAt),
        ]
        if let date = reflection.reflectionDate { output["date"] = dayFormatter.string(from: date) }
        return output
    }

    private static func evidenceObject(_ item: ReflectionEvidence) -> [String: Any] {
        var output: [String: Any] = [
            "id": item.id,
            "sourceID": item.sourceID,
            "sourceKind": item.sourceKind.rawValue,
            "claimKind": item.claimKind.rawValue,
            "label": item.label,
            "excerpt": item.excerpt,
        ]
        if let value = item.timestampMS { output["timestampMS"] = value }
        if let value = item.sourceURL { output["sourceURL"] = value }
        return output
    }

    private static func messageObject(_ message: ReflectionMessage) -> [String: Any] {
        ["id": message.id, "role": message.role.rawValue, "content": message.content,
         "evidenceIDs": message.evidenceIDs, "createdAt": timestamp(message.createdAt)]
    }

    private static func synthesisMarkdown(_ synthesis: LocalReflectionSynthesis) -> String {
        synthesis.sections.map { section in
            let statements = section.statements.map { statement in
                "- \(statement.text) [\(statement.evidenceIDs.joined(separator: ", "))]"
            }.joined(separator: "\n")
            return "### \(section.kind.rawValue)\n\n\(statements)"
        }.joined(separator: "\n\n")
    }

    private static func claimID(section: ReflectionSectionKind, offset: Int,
                                text: String) -> String {
        "claim-\(stableHash("\(section.rawValue)|\(offset)|\(text)"))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private static func uniqueEvidenceIDs(_ values: [String]) -> [String] {
        values.reduce(into: []) { output, id in
            if !id.isEmpty, !output.contains(id) { output.append(id) }
        }
    }

    private static func canonicalTargetURL(_ target: NotionTarget) -> String {
        "https://www.notion.so/\(target.id.replacingOccurrences(of: "-", with: ""))"
    }

    private static func fixtureFromProcess() -> String? {
        let allowed = Set(["1", "empty", "error", "notoken"])
        if let value = ProcessInfo.processInfo.environment["MIMO_REFLECTION_FIXTURE"],
           allowed.contains(value) { return value }
        let prefix = "--reflection-fixture="
        return ProcessInfo.processInfo.arguments.compactMap { argument -> String? in
            guard argument.hasPrefix(prefix) else { return nil }
            let value = String(argument.dropFirst(prefix.count))
            return allowed.contains(value) ? value : nil
        }.first
    }

    private static func contentSignature(_ snapshot: NotionSyncSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        return snapshot.records.sorted { $0.pageID < $1.pageID }.map {
            "\($0.pageID)|\($0.lastEditedAt.timeIntervalSince1970)"
        }
    }

    private var preferredLanguage: String {
        Locale.preferredLanguages.first ?? "zh-CN"
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

    private static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

    private func showNativeError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Mimo Reflection Browser"
        alert.informativeText = message
        alert.runModal()
    }
}

private struct ReflectionBrowserPersistedState: Codable {
    var version = ReflectionBrowserController.stateVersion
    var target: NotionTarget?
    /// Canonical non-sensitive target URL only; the integration token is never
    /// a field in this type and therefore cannot reach reflection-state.json.
    var targetURL: String?
    var rangeMode = "today"
    var customStart: Date?
    var customEnd: Date?
    var ignoredApps: [String] = []
    var ignoredDomains: [String] = []
    /// Set by “Delete Everything”. The selected connection stays available,
    /// but launch refresh remains off until the next explicit manual Sync.
    var notionRefreshSuspended: Bool? = false
    var marks: [ReflectionMark] = []
    var conversation = ReflectionConversation(
        id: "reflection-main", title: "Mimo Reflection Browser")
    var synthesis: LocalReflectionSynthesis?
    var synthesisDraft: SynthesisDraft?
    var writebackPreview: NotionWritebackPreview?
    var writebackError: String?
}
