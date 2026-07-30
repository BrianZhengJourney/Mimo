// Mimo — productization layer
// settings window (HTML), data retention/eraser, git-commit celebration

import Cocoa
import WebKit
import ServiceManagement
import UniformTypeIdentifiers
import ImageIO

struct PendingCandidateBoardDraft {
    let pngData: Data
    let candidatePNGs: [Data]
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    let styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    var lastTouchedAt: Date
}

struct PendingEvolutionSheetDraft {
    var pngData: Data
    var stagePNGs: [Data]
    let masterPNG: Data
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    var styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    let quality: PetFinalGenerationQuality
    var stageQualities: [PetFinalGenerationQuality]
    var lastTouchedAt: Date
    var relatedRequestIDs: [String]
}

struct CandidateGenerationRecovery {
    let rawPNG: Data
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    let styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    let providerSeconds: Double
    let usage: PetGenerationUsage
    let styleBoardUsed: Bool
    let createdAt: Date
}

struct EvolutionGenerationRecovery {
    let rawPNG: Data
    let masterPNG: Data
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    let styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    let quality: PetFinalGenerationQuality
    let providerSeconds: Double
    let usage: PetGenerationUsage
    let candidateDraftID: String
    let styleBoardUsed: Bool
    let createdAt: Date
}

struct PendingReferencePreflight {
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    let styleTuningNote: String
    let profile: CustomPetTemperamentProfile
    let likeness: Double
    let createdAt: Date
}

struct StageGenerationRecovery {
    let rawPNG: Data
    let parentDraftID: String
    let stage: PetEvolutionStage
    let quality: PetFinalGenerationQuality
    let styleTuningNote: String
    let providerSeconds: Double
    let usage: PetGenerationUsage
    let styleBoardUsed: Bool
    let createdAt: Date
}

enum PendingLocalGenerationRecovery {
    case candidates(CandidateGenerationRecovery)
    case evolution(EvolutionGenerationRecovery)
    case replacement(StageGenerationRecovery)

    var createdAt: Date {
        switch self {
        case .candidates(let value): return value.createdAt
        case .evolution(let value): return value.createdAt
        case .replacement(let value): return value.createdAt
        }
    }
}

// ── data retention & privacy eraser ─────────────────────────

func pruneOldLogs() {
    let days = UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 90
    guard days > 0 else { return }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) else { return }
    for url in files where url.lastPathComponent.hasPrefix("activity-") {
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "activity-", with: "")
        if let d = logDateFormatter.date(from: name), d < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Drop everything recorded after `ts` (ms epoch).
///
/// Returns false if any day's file could not be rewritten, so the caller can
/// avoid telling the user their history is gone when it is not.
@discardableResult
func eraseSince(_ ts: Double) -> Bool {
    var ok = true
    for day in logDaysToErase(after: ts) {
        let url = logURL(for: day)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let kept = retainedLogLines(in: text, erasingAfter: ts)
        let out = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { ok = false }
    }
    return ok
}

/// A silent write failure used to read as a successful erase.
func warnEraseIncomplete() {
    let a = NSAlert()
    a.messageText = voice("部分记录没有删除成功", "Some entries could not be erased")
    a.informativeText = voice("写入日志文件时出错，部分记录仍在这台 Mac 上。可以再试一次。",
                              "Writing the log files failed, so some entries are still on this Mac. You can try again.")
    a.alertStyle = .warning
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

func eraseAllHistory() {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: logDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix("activity-") && entry.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: entry)
        } else if name == "exports" {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

func historyStats() -> String {
    guard let files = try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.fileSizeKey]) else { return voice("还没有数据", "no data yet") }
    let logs = files.filter { $0.lastPathComponent.hasPrefix("activity-") }
    let bytes = logs.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
    return voice("本地保存了 \(logs.count) 天 · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · 全部只在这台 Mac 上",
                 "\(logs.count) day\(logs.count == 1 ? "" : "s") on disk · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · all local")
}

// ── automation permission status (no prompt) ────────────────

func automationStatus(_ bundleId: String) -> OSStatus {
    let desc = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let aeDesc = desc.aeDesc else { return -1 }
    return AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
}

/// Bounded: this is keyed by bundle id and holds a base64 PNG each, so an
/// unbounded dictionary grew monotonically with every app the user ever
/// focused, for the life of the process.
private let appIconCacheLimit = 256
var appIconCache: [String: String] = [:]
private var appIconCacheOrder: [String] = []

private func rememberAppIcon(_ bundleId: String, _ uri: String) {
    if appIconCache[bundleId] == nil { appIconCacheOrder.append(bundleId) }
    appIconCache[bundleId] = uri
    while appIconCacheOrder.count > appIconCacheLimit {
        appIconCache.removeValue(forKey: appIconCacheOrder.removeFirst())
    }
}

func appIconDataURI(_ bundleId: String) -> String? {
    if let hit = appIconCache[bundleId] { return hit.isEmpty ? nil : hit }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
        rememberAppIcon(bundleId, "")
        return nil
    }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    let small = NSImage(size: NSSize(width: 32, height: 32))
    small.lockFocus()
    icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    let uri = "data:image/png;base64," + png.base64EncodedString()
    rememberAppIcon(bundleId, uri)
    return uri
}

func petReferenceDataURI(_ url: URL) -> String? {
    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
    guard fileSize > 0, fileSize <= 20 * 1024 * 1024,
          let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          width.intValue > 0, height.intValue > 0,
          width.intValue <= 16_384, height.intValue <= 16_384,
          Int64(width.intValue) * Int64(height.intValue) <= 100_000_000 else { return nil }
    // Preserve enough detail for local face/person detection in tall social
    // screenshots and collage panels. Do not letterbox: black/empty borders
    // are precisely the noise the reference preflight needs to discard.
    let maximumDimension = 2_048
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        imageSource, 0, options as CFDictionary) else { return nil }
    let rep = NSBitmapImageRep(cgImage: thumbnail)
    guard let jpeg = rep.representation(using: .jpeg,
                                        properties: [.compressionFactor: 0.88]) else { return nil }
    return "data:image/jpeg;base64," + jpeg.base64EncodedString()
}

func validGeneratedPetSpec(_ spec: [String: Any]) -> Bool {
    func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        guard let number = value as? NSNumber,
              number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    guard integer(spec["schemaVersion"]) == 1,
          let name = spec["name"] as? String,
          (1...60).contains(name.count),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          let palette = spec["PAL"] as? [String: String], (7...16).contains(palette.count),
          Set(["P", "L", "A", "D", "K", "W", "M"]).isSubset(of: Set(palette.keys)),
          palette.allSatisfy({ key, value in
              key.count == 1 && value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
          }),
          let base = spec["BASE"] as? [String], (6...24).contains(base.count),
          let width = base.first?.count, (6...24).contains(width) else { return false }

    let height = base.count
    let allowed = Set(palette.keys.compactMap(\.first)).union([Character(".")])
    func validRows(_ rows: [String]) -> Bool {
        rows.count == height && rows.joined().contains(where: { $0 != "." }) && rows.allSatisfy { row in
            row.count == width && row.allSatisfy { allowed.contains($0) }
        }
    }
    guard validRows(base),
          let forms = spec["EVOLUTION_BASES"] as? [[String]],
          (1...3).contains(forms.count), forms.allSatisfy(validRows),
          let face = spec["face"] as? [String: Any],
          let lx = integer(face["lx"]), let rx = integer(face["rx"]),
          let y = integer(face["y"]), let mx = integer(face["mx"]), let my = integer(face["my"]),
          (1..<(width - 2)).contains(lx), (lx + 2..<(width - 1)).contains(rx),
          (1..<(height - 1)).contains(y), (1..<(width - 1)).contains(mx),
          (0..<(height - 1)).contains(my) else { return false }

    func validPixels(_ value: Any?) -> Bool {
        guard let pixels = value as? [Any], (1...64).contains(pixels.count) else { return false }
        return pixels.allSatisfy { value in
            guard let pixel = value as? [Any], pixel.count == 3,
                  let x = integer(pixel[0]), let y = integer(pixel[1]),
                  let token = pixel[2] as? String, token.count == 1,
                  palette[token] != nil else { return false }
            return (0..<width).contains(x) && (0..<height).contains(y)
        }
    }
    guard validPixels(spec["EYES"]), validPixels(spec["MOUTH"]) else { return false }

    if let viewBox = spec["vb"] as? String {
        let tokens = viewBox.split(whereSeparator: \.isWhitespace)
        let values = tokens.compactMap { Double(String($0)) }
        guard tokens.count == 4, values.count == 4, values.allSatisfy(\.isFinite),
              values[0] >= -64, values[1] >= -64,
              values[2] > 0, values[2] <= 64, values[3] > 0, values[3] <= 64 else { return false }
    }
    return true
}

func defaultBrowserBundleId() -> String? {
    guard let url = URL(string: "https://example.com"),
          let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
          let bundle = Bundle(url: appURL) else { return nil }
    return bundle.bundleIdentifier
}

// ── git commit watcher → proud celebration ──────────────────
// polls .git/logs/HEAD mtimes under the projects folder every 30s

final class GitWatcher {
    var timer: Timer?
    private var mtimes: [String: Date] = [:]
    var onCommit: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.brianzheng.mimo.git-watcher", qos: .utility)

    static func projectsDir() -> URL {
        if let p = UserDefaults.standard.string(forKey: "projectsDir") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/GitHub")
    }

    func start() {
        scheduleScan(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.scheduleScan(initial: false)
        }
    }

    func resetAndScan() {
        queue.async { [weak self] in
            guard let self else { return }
            self.mtimes.removeAll()
            self.scan(initial: true)
        }
    }

    private func scheduleScan(initial: Bool) {
        queue.async { [weak self] in self?.scan(initial: initial) }
    }

    private func scan(initial: Bool) {
        let dir = GitWatcher.projectsDir()
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for repo in kids {
            let head = repo.appendingPathComponent(".git/logs/HEAD")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: head.path),
                  let m = attrs[.modificationDate] as? Date else { continue }
            let key = repo.lastPathComponent
            defer { mtimes[key] = m }
            guard !initial, let prev = mtimes[key], m > prev else { continue }
            if let text = try? String(contentsOf: head, encoding: .utf8),
               let last = text.split(separator: "\n").last,
               last.contains("commit") {
                DispatchQueue.main.async { [weak self] in self?.onCommit?(key) }
            }
        }
    }
}

// ── the one settings window (hosts settings.html) ───────────

extension AppDelegate {

    func settingsCall(_ function: String, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsWeb?.evaluateJavaScript("\(function)(\(json))", completionHandler: nil)
    }

    func storedCustomPetSpec() -> [String: Any]? {
        guard let json = UserDefaults.standard.string(forKey: "customPetSpec"),
              let data = json.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validGeneratedPetSpec(spec) else { return nil }
        return spec
    }

    func restoreCustomPetIfNeeded() {
        // Repair legacy sheets once, off the main thread, instead of letting
        // every image load rewrite them from inside the store lock.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.customPetStore.repairStoredSheets()
        }
        if let spec = storedCustomPetSpec(),
           let data = try? JSONSerialization.data(withJSONObject: spec),
           let json = String(data: data, encoding: .utf8) {
            js("famRegisterPrototypePet(\(json), false)")
        }
        let customPets = (try? customPetStore.listRuntimeSpecs()) ?? []
        for spec in customPets {
            guard let data = try? JSONSerialization.data(withJSONObject: spec),
                  let json = String(data: data, encoding: .utf8) else { continue }
            js("famRegisterCustomPet(\(json), false)")
        }
        let builtins: Set<String> = ["lulu", "clawd", "nat"]
        let customIDs = Set(customPets.compactMap { $0["characterID"] as? String })
        let requested = UserDefaults.standard.string(forKey: "character") ?? "lulu"
        let valid = builtins.contains(requested)
            || (requested == "prototype" && storedCustomPetSpec() != nil)
            || customIDs.contains(requested)
        let selected = valid ? requested : "lulu"
        if selected != requested { UserDefaults.standard.set(selected, forKey: "character") }
        js("famSetCharacter(\(jsonStr(selected)))")
    }

    @objc func showSettings() {
        pruneStudioState()
        touchVisibleStudioDrafts()
        studioNotice = nil
        statusItem?.button?.toolTip = "Mimo"
        if let w = settingsWin {
            pushSettingsState()
            presentSettingsWindow(w)
            return
        }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "settings")
        cfg.setURLSchemeHandler(CustomPetAssetSchemeHandler(store: customPetStore),
                                forURLScheme: CustomPetStore.scheme)
        cfg.setURLSchemeHandler(
            ActionGenerationJobAssetSchemeHandler(store: actionGenerationJobStore),
            forURLScheme: ActionGenerationJobStore.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 780), configuration: cfg)
        web.navigationDelegate = self
        if let dir = Bundle.main.resourceURL {
            web.loadFileURL(dir.appendingPathComponent("settings.html"), allowingReadAccessTo: dir)
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 780),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = voice("Mimo 米墨", "Mimo")
        win.delegate = self
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.center()
        settingsWeb = web
        settingsWin = win
        presentSettingsWindow(win)
    }

    private func presentSettingsWindow(_ window: NSWindow) {
        // Mimo is an accessory app and its ambient overlay joins every Space.
        // A normal Settings window does not, so reopening it can otherwise
        // order the window on its previous Space while leaving it invisible on
        // the Space where the user invoked Settings.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWin else { return }
        touchVisibleStudioDrafts()
        if let requestID = studioGenerationLedger.activeRequestID {
            backgroundStudioRequests.insert(requestID)
        }
    }

    private func touchVisibleStudioDrafts(now: Date = Date()) {
        if let visibleEvolutionDraftID,
           var value = pendingEvolutionSheets[visibleEvolutionDraftID] {
            value.lastTouchedAt = now
            pendingEvolutionSheets[visibleEvolutionDraftID] = value
        }
        if let visibleCandidateDraftID,
           var value = pendingCandidateBoards[visibleCandidateDraftID] {
            value.lastTouchedAt = now
            pendingCandidateBoards[visibleCandidateDraftID] = value
        }
    }

    func permLine(_ code: OSStatus) -> String {
        switch code {
        case 0: return voice("已授权——米墨可以读取标签页地址", "granted — Mimo can read tab addresses")
        case -1744: return voice("尚未启用", "not yet enabled")
        case -1743: return voice("已拒绝——系统设置 → 隐私与安全性 → 自动化", "denied — System Settings → Privacy → Automation")
        case -600: return voice("打开浏览器，然后点击启用", "open your browser, then click Enable")
        default: return voice("找不到默认浏览器", "no default browser found")
        }
    }

    func pushSettingsState() {
        let d = UserDefaults.standard
        let bid = defaultBrowserBundleId()
        let code = bid.map { automationStatus($0) } ?? OSStatus(-1)
        var rules: [[String: Any]] = []
        for (key, label) in seenItems {
            var row: [String: Any] = ["key": key, "label": label,
                                      "kind": ruleOverrides[key] ?? defaultKind(key)]
            if let uri = appIconDataURI(key) { row["icon"] = uri }          // local app icon only
            rules.append(row)
        }
        rules.sort { ($0["label"] as? String ?? "").lowercased() < ($1["label"] as? String ?? "").lowercased() }
        var state: [String: Any] = [
            "character": d.string(forKey: "character") ?? "lulu",
            "language": voiceLanguage(),
            "permCode": Int(code),
            "permText": permLine(code),
            "rules": rules,
            "idle": d.object(forKey: "idleThreshold") as? Double ?? 150,
            "companionScalePercent": Double(companionDisplayScalePercent()),
            "retention": d.object(forKey: "retentionDays") as? Int ?? 90,
            "sounds": d.bool(forKey: "soundOn"),
            "login": SMAppService.mainApp.status == .enabled,
            "stats": historyStats(),
            "projects": GitWatcher.projectsDir().lastPathComponent,
            "pixelLabConfigured": MimoSecret.pixelLab.isConfigured,
            "openAIConfigured": MimoSecret.openAI.isConfigured,
            "openAIKeySource": MimoSecret.openAI.source.rawValue,
            "imageQuality": PetFinalGenerationQuality.resolve(
                d.string(forKey: "petImageQuality")).rawValue,
            "generationRecoveryCount": generationDraftStore.recoverableDraftCount(),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ]
        if let customPet = storedCustomPetSpec() { state["customPet"] = customPet }
        let customPets = (try? customPetStore.listRuntimeSpecs()) ?? []
        state["customPets"] = customPets
        for characterID in customPets.compactMap({ $0["characterID"] as? String }) {
            _ = try? starterActionJobStore.ensureJobs(characterID: characterID)
        }
        state["actionJobs"] = actionGenerationJobStore.runtimeDictionaries()
        state["starterActionJobs"] = starterActionJobStore.runtimeDictionaries()
        let starterPackActive = starterActionPackActiveJobID != nil
            || !starterActionPackQueue.isEmpty
        state["starterActionPack"] = [
            "active": starterPackActive,
            "activeJobID": starterActionPackActiveJobID ?? "",
            "remainingCount": starterActionPackQueue.count
                + (starterActionPackActiveJobID == nil ? 0 : 1),
            "totalCount": StarterActionID.allCases.count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        settingsWeb?.evaluateJavaScript("initSettings(\(json))", completionHandler: nil)
    }

    private func generationRequestID(_ value: Any?) -> String? {
        guard let value = value as? String, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func activeCustomCharacterID(requested: Any? = nil) -> String? {
        let active = UserDefaults.standard.string(forKey: "character") ?? ""
        if let requested = requested as? String, requested != active { return nil }
        guard active.hasPrefix(CustomPetStore.characterPrefix),
              (try? customPetStore.runtimeSpec(characterID: active)) != nil else { return nil }
        return active
    }

    private func reportActionJobError(_ error: Error, code: String) {
        settingsCall("actionJobError", [
            "code": code,
            "messageZh": "无法处理这个动作：\(error.localizedDescription)",
            "messageEn": "Could not process this action: \(error.localizedDescription)",
        ])
    }

    /// Decodes the bounded, browser-normalized reference set without retaining
    /// filenames or source bytes beyond the local preflight closure. Primary is
    /// moved first because it anchors conservative same-subject grouping.
    private func petReferenceInputs(_ body: [String: Any]) -> [MimoReferenceInput]? {
        struct Row {
            let id: String
            let data: Data
            let order: Int
            let primary: Bool
        }

        let primaryID = body["primaryReferenceID"] as? String
        var rows: [Row] = []
        var seen = Set<String>()
        var totalBytes = 0
        if let references = body["references"] as? [[String: Any]], !references.isEmpty {
            guard references.count <= 8 else { return nil }
            for (index, reference) in references.enumerated() {
                guard let id = reference["id"] as? String,
                      !id.isEmpty, id.utf8.count <= 128, seen.insert(id).inserted,
                      let source = reference["source"] as? String,
                      source.hasPrefix("data:image/"), source.utf8.count < 28_000_000,
                      let data = PetGenerationCoordinator.dataFromDataURI(source),
                      !data.isEmpty, data.count <= 20 * 1024 * 1024,
                      PetGenerationCoordinator.isSupportedImageData(data),
                      totalBytes <= 64 * 1024 * 1024 - data.count else { return nil }
                totalBytes += data.count
                let order = (reference["order"] as? NSNumber)?.intValue ?? index
                rows.append(Row(id: id, data: data, order: order,
                                primary: id == primaryID || reference["role"] as? String == "primary"))
            }
        } else {
            guard let source = body["source"] as? String,
                  source.hasPrefix("data:image/"), source.utf8.count < 28_000_000,
                  let data = PetGenerationCoordinator.dataFromDataURI(source),
                  !data.isEmpty, data.count <= 20 * 1024 * 1024,
                  PetGenerationCoordinator.isSupportedImageData(data) else { return nil }
            rows = [Row(id: "legacy-primary", data: data, order: 0, primary: true)]
        }
        guard !rows.isEmpty else { return nil }
        rows.sort {
            if $0.primary != $1.primary { return $0.primary && !$1.primary }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
        return rows.map { MimoReferenceInput(id: $0.id, data: $0.data) }
    }

    private func pushPetReferenceAnalysis(_ result: MimoReferencePreprocessingResult) {
        let usedIDs = Set(result.providerPayload?.identityBoard.sourceInputIDs ?? [])
        let rows: [[String: Any]] = result.images.map { image in
            var zh: [String] = []
            var en: [String] = []
            let used = usedIDs.contains(image.inputID)
            zh.append(used ? "✓ 身份板采用" : "未采用")
            en.append(used ? "✓ used in board" : "not used")
            if let person = image.usablePeople.first {
                var zhDetail = "人物 ×\(max(1, image.detectedPersonCount))"
                var enDetail = "person ×\(max(1, image.detectedPersonCount))"
                switch person.view {
                case .frontal: zhDetail += " · 正面"; enDetail += " · front"
                case .threeQuarter: zhDetail += " · 3/4"; enDetail += " · 3/4"
                case .profile: zhDetail += " · 侧脸"; enDetail += " · profile"
                case .unknown: break
                }
                zh.append(zhDetail); en.append(enDetail)
            } else if used {
                zh.append("主体备用"); en.append("subject fallback")
            } else {
                zh.append("未找到清楚人物"); en.append("no clear person")
            }
            return [
                "id": image.inputID,
                "status": "ready",
                "badgesZh": Array(zh.prefix(2)),
                "badgesEn": Array(en.prefix(2)),
            ]
        }
        settingsCall("petReferenceAnalysis", ["references": rows])
    }

    func startStudioCleanup() {
        studioCleanupTimer?.invalidate()
        studioCleanupTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.pruneStudioState()
        }
    }

    func pruneStudioState(now: Date = Date()) {
        let sessionCutoff = now.addingTimeInterval(-30 * 60)
        let ledgerCutoff = now.addingTimeInterval(-FamiliarGenerationDraftStore.retention)
        let expiredPreflights = pendingReferencePreflights.compactMap { key, value in
            value.createdAt < sessionCutoff ? key : nil
        }
        for requestID in expiredPreflights {
            pendingReferencePreflights.removeValue(forKey: requestID)
            if studioGenerationLedger.activeRequestID == requestID {
                releaseStudioGeneration(requestID)
                backgroundStudioRequests.remove(requestID)
            }
        }
        pendingLocalRecoveries = pendingLocalRecoveries.filter { $0.value.createdAt >= sessionCutoff }
        let recoveryParentIDs = pendingLocalRecoveries.values.compactMap { recovery -> String? in
            if case .replacement(let value) = recovery { return value.parentDraftID }
            return nil
        }
        var pinnedEvolutionIDs = Set(activeStageParents.values).union(recoveryParentIDs)
        if settingsWin?.isVisible == true, let visibleEvolutionDraftID {
            pinnedEvolutionIDs.insert(visibleEvolutionDraftID)
        }
        pendingEvolutionSheets = retainingStudioDrafts(
            pendingEvolutionSheets, newerThan: sessionCutoff,
            pinnedIDs: pinnedEvolutionIDs, lastTouchedAt: { $0.lastTouchedAt })
        let recoveryCandidateIDs = pendingLocalRecoveries.values.compactMap { recovery -> String? in
            if case .evolution(let value) = recovery { return value.candidateDraftID }
            return nil
        }
        let pinnedCandidateIDs = Set(pendingEvolutionSheets.values.flatMap(\.relatedRequestIDs))
            .union(recoveryCandidateIDs)
            .union(settingsWin?.isVisible == true
                   ? visibleCandidateDraftID.map { Set([$0]) } ?? [] : [])
        pendingCandidateBoards = retainingStudioDrafts(
            pendingCandidateBoards, newerThan: sessionCutoff,
            pinnedIDs: pinnedCandidateIDs, lastTouchedAt: { $0.lastTouchedAt })
        if let visibleEvolutionDraftID,
           pendingEvolutionSheets[visibleEvolutionDraftID] == nil {
            self.visibleEvolutionDraftID = nil
            settingsCall("petDraftExpired", ["kind": "evolution", "draftID": visibleEvolutionDraftID])
        }
        if let visibleCandidateDraftID,
           pendingCandidateBoards[visibleCandidateDraftID] == nil {
            self.visibleCandidateDraftID = nil
            settingsCall("petDraftExpired", ["kind": "candidate", "draftID": visibleCandidateDraftID])
        }
        // Drop bookkeeping for requests that are no longer live. These are only
        // cleared inside completion handlers gated on the ledger's active ID,
        // so a dropped callback used to leak an entry that pinned a
        // multi-megabyte draft for the rest of the process.
        let liveRequestIDs = Set(pendingReferencePreflights.keys)
            .union(pendingLocalRecoveries.keys)
            .union(studioGenerationLedger.activeRequestID.map { Set([$0]) } ?? [])
        activeStageParents = activeStageParents.filter { liveRequestIDs.contains($0.key) }
        backgroundStudioRequests = backgroundStudioRequests.intersection(
            liveRequestIDs.union(pendingEvolutionSheets.keys).union(pendingCandidateBoards.keys))
        studioGenerationLedger.prune(before: ledgerCutoff)
        _ = try? generationDraftStore.purgeExpired(now: now)
    }

    private func announceStudioBackground(_ requestID: String, kind: String,
                                          _ zh: String, _ en: String) {
        guard backgroundStudioRequests.remove(requestID) != nil else { return }
        let message = voice(zh, en)
        studioNotice = message
        statusItem?.button?.toolTip = message
        js("famNotice(\(jsonStr(kind)), \(jsonStr(message)))")
    }

    private func reserveProviderGeneration(_ requestID: String) -> Bool {
        switch studioGenerationLedger.reserve(requestID: requestID) {
        case .accepted:
            return true
        case .duplicateActive:
            settingsCall("petStudioProgress", [
                "requestID": requestID, "phase": "generating",
                "messageZh": "这个请求已经在进行，不会重复扣费。",
                "messageEn": "This request is already running; Mimo did not submit it twice.",
            ])
        case .anotherRequestActive:
            settingsCall("petStudioError", [
                "requestID": requestID, "kind": "setup", "phase": "busy",
                "code": "generation_in_progress",
                "messageZh": "另一个生成还在进行；米墨没有发出第二个付费请求。",
                "messageEn": "Another generation is still running; Mimo did not submit a second paid request.",
                "outputRetained": false, "requestNotStarted": true,
            ])
        case .requestIDReused:
            settingsCall("petStudioError", [
                "requestID": requestID, "kind": "setup", "phase": "input",
                "code": "request_id_reused",
                "messageZh": "这个请求编号已经用过；为避免重复扣费，米墨没有再次提交。",
                "messageEn": "This request ID was already used; Mimo did not resubmit it and risk a duplicate charge.",
                "outputRetained": false, "requestNotStarted": true,
            ])
        }
        return false
    }

    private func reserveLocalProcessing(_ requestID: String) -> Bool {
        studioGenerationLedger.reserveLocalProcessing(requestID: requestID)
    }

    private func studioProgress(requestID: String, phase: String, startedAt: Date,
                                partial: Data? = nil, providerSeconds: Double? = nil,
                                localSeconds: Double? = nil, warnings: [String] = []) {
        var payload: [String: Any] = [
            "requestID": requestID,
            "phase": phase,
            "elapsedSeconds": Date().timeIntervalSince(startedAt),
        ]
        if let partial { payload["partialImage"] = PetGenerationCoordinator.dataURI(partial) }
        if let providerSeconds { payload["providerSeconds"] = providerSeconds }
        if let localSeconds { payload["localSeconds"] = localSeconds }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        settingsCall("petStudioProgress", payload)
    }

    private func boundaryWarnings(_ quality: CharacterSheetQualityMetadata) -> [[String: String]] {
        let boundary = quality.boundaryRecoveries.map {
            [
                "zh": "已把内部第 \($0.boundaryIndex + 1) 条分隔参考线从 x=\($0.nominalX) 调整到真实空隙 x=\($0.resolvedX)。",
                "en": "Recovered divider \($0.boundaryIndex + 1) from x=\($0.nominalX) to x=\($0.resolvedX).",
            ]
        }
        let nearEdge = quality.nearEdgeRecoveries.map {
            [
                "zh": "第 \($0 + 1) 个形态很靠近画布，但仍有完整边距；已用安全恢复模式提取。",
                "en": "Recovered complete form \($0 + 1) from a narrow but nonzero canvas margin.",
            ]
        }
        return boundary + nearEdge
    }

    private func localProcessingCopy(_ error: Error) -> (code: String, zh: String, en: String) {
        guard let value = error as? CharacterSheetProcessingError else {
            return ("local_processing_failed",
                    "米墨的本机处理没有完成；OpenAI 原始结果仍可查看。",
                    error.localizedDescription)
        }
        switch value {
        case .notPNG:
            return ("not_png", "OpenAI 返回的文件不是可处理的 PNG。", value.localizedDescription)
        case .unreadableImage:
            return ("unreadable_image", "这张生成图在本机无法解码。", value.localizedDescription)
        case .invalidDimensions(let width, let height):
            return ("invalid_sheet_dimensions", "成长图尺寸应为 1536×1024，实际是 \(width)×\(height)。", value.localizedDescription)
        case .invalidCandidateBoardDimensions(let width, let height):
            return ("invalid_candidate_dimensions", "候选图尺寸应为 1024×1024，实际是 \(width)×\(height)。", value.localizedDescription)
        case .invalidSingleStageDimensions(let width, let height):
            return ("invalid_stage_dimensions", "单段重画尺寸应为 1024×1024，实际是 \(width)×\(height)。", value.localizedDescription)
        case .invalidNormalizedSheetDimensions, .invalidNormalizedStageDimensions:
            return ("invalid_local_asset", "本机透明角色图的尺寸不符合安装格式。", value.localizedDescription)
        case .emptyStage(let index):
            return ("empty_form", "第 \(index + 1) 个形态是空的。", value.localizedDescription)
        case .stageTooSmall(let index):
            return ("form_too_small", "第 \(index + 1) 个形态太小，无法安全变成桌面角色。", value.localizedDescription)
        case .stageTouchesMargin(let index):
            return ("form_near_edge", "第 \(index + 1) 个形态离真实画布边缘太近；可免费尝试更宽容的安全提取。", value.localizedDescription)
        case .stagesMerged(let boundary):
            return ("forms_merged", "第 \(boundary + 1) 和第 \(boundary + 2) 个形态粘在一起，无法无损分开。", value.localizedDescription)
        case .normalizedStageHasBackground:
            return ("background_not_removed", "单段重画仍带有不透明背景，不能覆盖已接受的角色图。", value.localizedDescription)
        case .encodingFailed:
            return ("local_encoding_failed", "本机无法编码最终透明角色图。", value.localizedDescription)
        }
    }

    private func providerFailureCopy(_ error: Error) -> (code: String, zh: String, en: String) {
        let detail = error.localizedDescription
        let lower = detail.lowercased()
        if let generation = error as? PetGenerationError, case .timedOut = generation {
            return ("provider_timeout", "OpenAI 这次生成超时了；没有可用的最终图片返回。", "OpenAI timed out before returning a usable final image.")
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                return ("network_timeout", "连接等待超时；请稍后重试。", "The connection timed out; try again shortly.")
            }
            return ("network_error", "连接 OpenAI 时中断了；请检查网络后重试。", "The connection to OpenAI was interrupted; check the network and try again.")
        }
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") {
            return ("rate_limited", "OpenAI 现在请求太多；等一会儿再试。", "OpenAI is rate-limiting requests; wait a moment and try again.")
        }
        if lower.contains("quota") || lower.contains("billing") || lower.contains("credit") || lower.contains("insufficient") {
            return ("quota_exhausted", "这个 OpenAI API 账户的额度或余额不足。", "This OpenAI API account has insufficient quota or credits.")
        }
        if lower.contains("safety") || lower.contains("content policy") || lower.contains("moderation") {
            return ("safety_rejected", "OpenAI 的安全检查没有接受这次图片请求；可以换一张参考图或调整描述。", "OpenAI safety checks rejected this image request; try another reference or description.")
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return ("provider_timeout", "这次生成等待超时；没有可用的最终图片返回。", "Generation timed out before a usable final image returned.")
        }
        return ("provider_failed", "OpenAI 没有返回可用的最终图片；可以稍后重试。", "OpenAI did not return a usable final image; try again later.")
    }

    private func canSalvageNearEdge(_ error: Error) -> Bool {
        guard let processing = error as? CharacterSheetProcessingError else { return false }
        if case .stageTouchesMargin = processing { return true }
        return false
    }

    /// Releases a studio reservation and stops any background preprocessing
    /// still polling for it. Both have to happen together, or a cancelled run
    /// keeps burning Vision passes on work nobody will read.
    private func releaseStudioGeneration(_ requestID: String) {
        studioGenerationLedger.finish(requestID: requestID)
        if activeStudioCancellationToken?.requestID == requestID {
            activeStudioCancellationToken?.cancel()
            activeStudioCancellationToken = nil
        }
    }

    private func retainedDraftExists(_ requestID: String) -> Bool {
        (try? generationDraftStore.manifest(requestID: requestID)) != nil
    }

    private func retainRaw(_ rawPNG: Data, requestID: String,
                           phase: FamiliarGenerationPhase, quality: String,
                           providerSeconds: Double) -> Bool {
        do {
            try generationDraftStore.saveRaw(requestID: requestID, pngData: rawPNG,
                                             phase: phase, quality: quality,
                                             providerSeconds: providerSeconds)
            return true
        } catch {
            NSLog("Mimo could not retain generated output %@: %@", requestID, error.localizedDescription)
            return false
        }
    }

    private func studioProviderError(requestID: String, error: Error,
                                     startedAt: Date, phase: String) {
        guard studioGenerationLedger.activeRequestID == requestID else { return }
        activeStageParents.removeValue(forKey: requestID)
        // Cancellation now arrives as a real completion so the ledger and the
        // draft bookkeeping always unwind. The user asked for it — release
        // everything, say nothing.
        if let generationError = error as? PetGenerationError, generationError.isCancellation {
            releaseStudioGeneration(requestID)
            pendingReferencePreflights.removeValue(forKey: requestID)
            settingsCall("petStudioCancelled", ["requestID": requestID])
            return
        }
        if let generationError = error as? PetGenerationError,
           case .missingKey = generationError {
            settingsCall("petStudioError", [
                "requestID": requestID, "kind": "setup", "phase": "input",
                "code": "missing_api_key",
                "messageZh": "请先连接 OpenAI；图片尚未发送，也不会产生费用。",
                "messageEn": "Connect OpenAI first; no image was sent and no cost was incurred.",
                "outputRetained": false, "requestNotStarted": true,
            ])
            releaseStudioGeneration(requestID)
            announceStudioBackground(requestID, kind: "warning", "生成前还需要检查 API 连接。", "Generation needs the API connection checked.")
            return
        }
        let copy = providerFailureCopy(error)
        settingsCall("petStudioError", [
            "requestID": requestID,
            "kind": "provider",
            "phase": phase,
            "code": copy.code,
            "message": copy.en,
            "messageZh": copy.zh,
            "messageEn": copy.en,
            "providerDetail": String(error.localizedDescription.prefix(1000)),
            "providerSeconds": Date().timeIntervalSince(startedAt),
            "outputRetained": false,
        ])
        releaseStudioGeneration(requestID)
        announceStudioBackground(requestID, kind: "error", "这次生成没有完成；打开设置可以查看原因。", "Generation did not finish; open Settings for details.")
    }

    private func studioLocalError(requestID: String, error: Error,
                                  rawPNG: Data, providerSeconds: Double,
                                  localSeconds: Double, outputRetained: Bool,
                                  canRetryLocally: Bool,
                                  warnings: [[String: String]] = []) {
        if outputRetained {
            _ = try? generationDraftStore.markLocalFailure(
                requestID: requestID, message: error.localizedDescription,
                localSeconds: localSeconds)
        }
        let copy = localProcessingCopy(error)
        var payload: [String: Any] = [
            "requestID": requestID,
            "kind": "local",
            "phase": "processing",
            "code": copy.code,
            "message": copy.en,
            "messageZh": copy.zh,
            "messageEn": copy.en,
            "providerSeconds": providerSeconds,
            "localSeconds": localSeconds,
            "rawPreview": PetGenerationCoordinator.dataURI(rawPNG),
            "outputRetained": outputRetained,
            "providerCompleted": true,
            "canRetryLocally": canRetryLocally,
        ]
        if canRetryLocally {
            payload["recoveryDraftID"] = requestID
            payload["recoveryUntil"] = Date().addingTimeInterval(30 * 60)
                .timeIntervalSince1970 * 1000
        }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        payload["generationRecoveryCount"] = generationDraftStore.recoverableDraftCount()
        settingsCall("petStudioError", payload)
        activeStageParents.removeValue(forKey: requestID)
        releaseStudioGeneration(requestID)
        announceStudioBackground(requestID, kind: "warning", "图片已回来，但本机检查没有通过；原图仍可查看。", "The image arrived, but local checks failed; the raw output is still available.")
    }

    private func prepareCandidateGeneration(requestID: String,
                                            inputs: [MimoReferenceInput],
                                            profile: CustomPetTemperamentProfile,
                                            likeness: Double,
                                            styleTuningNote: String,
                                            useDetectedPersonDefault: Bool) {
        guard reserveProviderGeneration(requestID) else { return }
        let startedAt = Date()
        studioProgress(requestID: requestID, phase: "analyzing", startedAt: startedAt)
        // The preprocessor polls isCancelled at least 2N+3 times per run. That
        // used to be a DispatchQueue.main.sync each time: a synchronous hop
        // that stalls the Vision pipeline on main-runloop latency, and
        // deadlocks outright if the main thread ever waits on this work. The
        // token is mirrored into a lock-protected box instead, which is what
        // process(_:isCancelled:) documents it wants.
        let cancellationToken = StudioCancellationToken(requestID: requestID)
        activeStudioCancellationToken = cancellationToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MimoReferencePreprocessor().process(inputs, isCancelled: {
                cancellationToken.isCancelled
            })
            let localSeconds = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async {
                guard let self,
                      self.studioGenerationLedger.activeRequestID == requestID else { return }
                self.pushPetReferenceAnalysis(result)
                guard let payload = result.providerPayload else {
                    self.settingsCall("petStudioError", [
                        "requestID": requestID,
                        "kind": "setup", "phase": "input",
                        "code": "reference_preflight_failed",
                        "messageZh": "这些图片里没有找到足够清楚的主体；没有调用 OpenAI，也没有产生费用。请把最清楚的人物或物体设为主参考。",
                        "messageEn": "Mimo could not find a clear enough subject in these images. OpenAI was not called and no cost was incurred. Make the clearest person or object the primary reference.",
                        "localSeconds": localSeconds,
                        "outputRetained": false, "requestNotStarted": true,
                    ])
                    self.releaseStudioGeneration(requestID)
                    self.announceStudioBackground(requestID, kind: "warning",
                                                  "参考图需要更清楚的主角。",
                                                  "The references need a clearer primary subject.")
                    return
                }
                let shouldUseDefault = useDetectedPersonDefault &&
                    styleTuningNote.isEmpty &&
                    payload.identityBoard.mode == .isolatedPeople
                let effectiveStyleTuningNote = shouldUseDefault
                    ? PetVisualTuningNote.detectedPersonDefault(language: voiceLanguage())
                    : styleTuningNote
                let boardURI = PetGenerationCoordinator.dataURI(payload.identityBoard.png)
                self.studioProgress(requestID: requestID, phase: "analyzing",
                                    startedAt: startedAt,
                                    partial: payload.identityBoard.png,
                                    localSeconds: localSeconds,
                                    warnings: payload.identityBoard.mode == .sanitizedFullFrames
                                      ? ["No reliable person was found; using a locally sanitized subject board."] : [])
                self.pendingReferencePreflights[requestID] = PendingReferencePreflight(
                    sourceDataURI: boardURI,
                    referenceEvidenceJSON: payload.analysisJSON,
                    styleTuningNote: effectiveStyleTuningNote,
                    profile: profile, likeness: likeness, createdAt: Date())
                let ambiguous = result.images.contains {
                    $0.warnings.contains(.identityAmbiguous)
                }
                self.settingsCall("petReferencePreview", [
                    "requestID": requestID,
                    "board": boardURI,
                    "mode": payload.identityBoard.mode.rawValue,
                    "sourceCount": result.images.count,
                    "usedSourceCount": Set(payload.identityBoard.sourceInputIDs).count,
                    "evidenceCount": payload.identityBoard.referenceIDs.count,
                    "ambiguous": ambiguous,
                    "localSeconds": localSeconds,
                    "defaultStyleTuningNote": shouldUseDefault ? effectiveStyleTuningNote : "",
                    "messageZh": ambiguous
                      ? "检测到不止一个可能的人物。请确认身份板里的主角正确；不对就取消并把最清楚的图设为主参考。"
                      : "请确认这就是你想做成伴灵的主角。确认前不会调用 OpenAI。",
                    "messageEn": ambiguous
                      ? "More than one possible person was detected. Confirm that the identity board shows the right subject, or cancel and make the clearest image primary."
                      : "Confirm that this is the subject you want to turn into a familiar. OpenAI is not called before confirmation.",
                ])
            }
        }
    }

    private func startCandidateGeneration(requestID: String, source: String,
                                          referenceEvidenceJSON: String,
                                          styleTuningNote: String,
                                          profile: CustomPetTemperamentProfile,
                                          likeness: Double,
                                          alreadyReserved: Bool = false) {
        guard alreadyReserved || reserveProviderGeneration(requestID) else { return }
        let startedAt = Date()
        let style = MimoStyleReference.requestData()
        petGenerator.generateCandidateBoard(
            requestID: requestID, sourceDataURI: source, styleBoardData: style,
            referenceEvidenceJSON: referenceEvidenceJSON,
            styleTuningNote: styleTuningNote,
            personalityVisual: profile.promptFragment, likeness: likeness,
            progress: { [weak self] phase, partial, _ in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                self.studioProgress(requestID: requestID, phase: phase,
                                    startedAt: startedAt, partial: partial)
            }, completion: { [weak self] result in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .failure(let error):
                    self.studioProviderError(requestID: requestID, error: error,
                                             startedAt: startedAt, phase: "candidates")
                case .success(let output):
                    let providerSeconds = Date().timeIntervalSince(startedAt)
                    let retained = self.retainRaw(
                        output.data, requestID: requestID, phase: .candidates,
                        quality: PetGenerationQuality.low.rawValue,
                        providerSeconds: providerSeconds)
                    let recovery = CandidateGenerationRecovery(
                        rawPNG: output.data, sourceDataURI: source,
                        referenceEvidenceJSON: referenceEvidenceJSON,
                        styleTuningNote: styleTuningNote,
                        temperamentID: profile.id, likeness: likeness,
                        providerSeconds: providerSeconds, usage: output.usage,
                        styleBoardUsed: style != nil, createdAt: Date())
                    self.pendingLocalRecoveries[requestID] = .candidates(recovery)
                    self.processCandidateGeneration(requestID: requestID,
                                                    recovery: recovery,
                                                    outputRetained: retained)
                }
            }
        )
    }

    private func processCandidateGeneration(requestID: String,
                                            recovery: CandidateGenerationRecovery,
                                            outputRetained: Bool,
                                            salvageNearEdge: Bool = false) {
        let localStartedAt = Date()
        studioProgress(requestID: requestID, phase: "processing",
                       startedAt: localStartedAt,
                       providerSeconds: recovery.providerSeconds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try CharacterSheetProcessor.processCandidateBoard(
                    pngData: recovery.rawPNG,
                    allowNearEdgeRecovery: salvageNearEdge)
            }
            let localSeconds = Date().timeIntervalSince(localStartedAt)
            DispatchQueue.main.async {
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .success(let board):
                    var warnings = self.boundaryWarnings(board.quality)
                    if !recovery.styleBoardUsed {
                        warnings.append([
                            "zh": "内置米墨风格板没有载入；这次只使用了文字风格约束。",
                            "en": "The bundled Mimo style board was unavailable; prompt-only styling was used.",
                        ])
                    }
                    // No markProcessed here: it validates and writes a
                    // multi-megabyte processed.png plus a re-encoded manifest,
                    // and the next line deleted the whole directory anyway. The
                    // draft has served its purpose once local processing
                    // succeeded.
                    _ = try? self.generationDraftStore.delete(requestID: requestID)
                    self.pendingCandidateBoards[requestID] = PendingCandidateBoardDraft(
                        pngData: board.pngData, candidatePNGs: board.candidatePNGs,
                        sourceDataURI: recovery.sourceDataURI,
                        referenceEvidenceJSON: recovery.referenceEvidenceJSON,
                        styleTuningNote: recovery.styleTuningNote,
                        temperamentID: recovery.temperamentID,
                        likeness: recovery.likeness, lastTouchedAt: Date())
                    self.visibleCandidateDraftID = requestID
                    self.pendingLocalRecoveries.removeValue(forKey: requestID)
                    self.settingsCall("petCandidateResult", [
                        "requestID": requestID,
                        "candidateDraftID": requestID,
                        "draftID": requestID,
                        "candidates": board.candidatePNGs.map(PetGenerationCoordinator.dataURI),
                        "sheet": PetGenerationCoordinator.dataURI(board.pngData),
                        "providerSeconds": recovery.providerSeconds,
                        "localSeconds": localSeconds,
                        "warnings": warnings,
                        "usage": recovery.usage.dictionary,
                        "model": "gpt-image-2", "size": "1024x1024",
                        "partialImages": 1,
                        "styleBoardUsed": recovery.styleBoardUsed,
                        "referenceCount": recovery.styleBoardUsed ? 2 : 1,
                        "generationRecoveryCount": self.generationDraftStore.recoverableDraftCount(),
                    ])
                    self.releaseStudioGeneration(requestID)
                    self.announceStudioBackground(requestID, kind: "success", "3 个 Low 草稿已经画好，打开设置来选主角。", "Three Low drafts are ready; open Settings to pick the master.")
                case .failure(let error):
                    let canRetry = !salvageNearEdge && self.canSalvageNearEdge(error)
                    if !canRetry { self.pendingLocalRecoveries.removeValue(forKey: requestID) }
                    self.studioLocalError(
                        requestID: requestID, error: error, rawPNG: recovery.rawPNG,
                        providerSeconds: recovery.providerSeconds,
                        localSeconds: localSeconds, outputRetained: outputRetained,
                        canRetryLocally: canRetry)
                }
            }
        }
    }

    // MARK: - Starter actions (post-adoption gaze/sleep/tennis/wall)

    private func starterActionDetail(_ error: Error) -> String {
        if let actionError = error as? ActionSheetError {
            return actionError.description
        }
        return error.localizedDescription
    }

    private func emitStarterActionJob(_ record: StarterActionJobRecord) {
        settingsCall("starterActionJobUpdated", [
            "job": starterActionJobStore.runtimeDictionary(for: record),
        ])
        guard record.id == starterActionPackActiveJobID,
              !record.state.isInFlight,
              [.awaitingReview, .installed, .failed, .cancelled]
                .contains(record.state) else { return }
        starterActionPackActiveJobID = nil
        DispatchQueue.main.async { [weak self] in
            self?.startNextStarterActionPackJob()
        }
    }

    private func reportStarterActionError(jobID: String?, error: Error,
                                          code: String) {
        var payload: [String: Any] = [
            "code": code,
            "messageZh": "动作生成没有完成：\(starterActionDetail(error))",
            "messageEn": "The action was not completed: \(starterActionDetail(error))",
        ]
        if let jobID { payload["jobID"] = jobID }
        settingsCall("starterActionJobError", payload)
    }

    private func reserveStarterActionProvider(requestID: String,
                                              jobID: String) -> Bool {
        switch studioGenerationLedger.reserve(requestID: requestID) {
        case .accepted:
            return true
        case .duplicateActive:
            reportStarterActionError(
                jobID: jobID,
                error: PetGenerationError.provider(
                    "This exact batch is already generating; no duplicate was submitted."),
                code: "duplicate_active")
        case .anotherRequestActive:
            reportStarterActionError(
                jobID: jobID,
                error: PetGenerationError.provider(
                    "Another image generation is running; no second paid request was submitted."),
                code: "generation_in_progress")
        case .requestIDReused:
            reportStarterActionError(
                jobID: jobID,
                error: PetGenerationError.provider(
                    "This batch request ID was already used; no replay was submitted."),
                code: "request_id_reused")
        }
        return false
    }

    private func disarmStarterActionWatchdog(_ requestID: String) {
        starterActionWatchdogs.removeValue(forKey: requestID)?.cancel()
    }

    private func armStarterActionWatchdog(jobID: String, requestID: String) {
        disarmStarterActionWatchdog(requestID)
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self,
                  let record = try? self.starterActionJobStore.record(jobID: jobID),
                  record.state == .generating,
                  record.requestID == requestID else { return }
            self.petGenerator.cancel(requestID)
            self.releaseStudioGeneration(requestID)
            self.disarmStarterActionWatchdog(requestID)
            let spent = min(
                record.usedProviderCalls + 1,
                record.estimatedProviderCalls * record.maximumAttempts)
            if let failed = try? self.starterActionJobStore.markFailed(
                jobID: jobID, code: "timed_out",
                message: "The provider callback timed out; completed batches remain saved.",
                usedProviderCalls: spent) {
                self.emitStarterActionJob(failed)
            }
            self.reportStarterActionError(
                jobID: jobID, error: PetGenerationError.timedOut,
                code: "timed_out")
            self.pushSettingsState()
        }
        starterActionWatchdogs[requestID] = watchdog
        DispatchQueue.main.asyncAfter(
            deadline: .now() + StudioGenerationLedger.reservationLifetime,
            execute: watchdog)
    }

    private func starterActionCanonicalContext(characterID: String) throws
        -> (master: Data, personality: String) {
        let spec = try customPetStore.runtimeSpec(characterID: characterID)
        guard let assetURLString = spec["assetURL"] as? String,
              let assetURL = URL(string: assetURLString),
              let temperamentID = spec["temperamentID"] as? String else {
            throw CustomPetStoreError.corruptManifest
        }
        let sheet = try customPetStore.assetData(for: assetURL)
        let master = try CharacterSheetProcessor.extractNormalizedStage(
            fromNormalizedSheet: sheet, stageIndex: 2)
        let profile = CustomPetTemperaments.profile(for: temperamentID)
        return (master, profile.promptFragment)
    }

    private func starterActionFailureMayHaveSpent(_ error: Error) -> Bool {
        guard let generation = error as? PetGenerationError else { return true }
        switch generation {
        case .missingKey, .invalidImage, .cancelled:
            return false
        case .invalidResponse, .provider, .timedOut:
            return true
        }
    }

    func startStarterActionPack(characterID: String,
                                quality: PetFinalGenerationQuality) {
        guard starterActionPackActiveJobID == nil,
              starterActionPackQueue.isEmpty else {
            pushSettingsState()
            return
        }
        do {
            let jobs = try starterActionJobStore.ensureJobs(
                characterID: characterID)
            let localRepairs = jobs.filter {
                $0.state == .failed && $0.canReprocess
            }
            let providerJobs = jobs.filter {
                $0.canStart && !localRepairs.contains($0)
            }
            starterActionPackQueue = (localRepairs + providerJobs).map(\.id)
            starterActionPackCharacterID = characterID
            starterActionPackQuality = quality
            pushSettingsState()
            startNextStarterActionPackJob()
        } catch {
            reportStarterActionError(
                jobID: nil, error: error, code: "pack_start_failed")
        }
    }

    private func startNextStarterActionPackJob() {
        guard starterActionPackActiveJobID == nil else { return }
        guard let characterID = starterActionPackCharacterID else {
            starterActionPackQueue.removeAll()
            pushSettingsState()
            return
        }
        while !starterActionPackQueue.isEmpty {
            let jobID = starterActionPackQueue.removeFirst()
            guard let record = try? starterActionJobStore.record(jobID: jobID),
                  record.characterID == characterID else { continue }
            if record.state == .failed && record.canReprocess {
                do {
                    starterActionPackActiveJobID = jobID
                    let local = try starterActionJobStore.beginLocalReprocess(
                        jobID: jobID)
                    emitStarterActionJob(local)
                    pushSettingsState()
                    processStarterActionLocally(jobID: jobID)
                    return
                } catch {
                    starterActionPackActiveJobID = nil
                    reportStarterActionError(
                        jobID: jobID, error: error,
                        code: "pack_local_reprocess_failed")
                    continue
                }
            }
            guard record.canStart else { continue }
            starterActionPackActiveJobID = jobID
            startStarterActionJob(
                jobID: jobID, characterID: characterID,
                quality: starterActionPackQuality)
            if let current = try? starterActionJobStore.record(jobID: jobID),
               current.state.isInFlight {
                pushSettingsState()
                return
            }
            starterActionPackActiveJobID = nil
        }
        starterActionPackCharacterID = nil
        pushSettingsState()
    }

    func cancelStarterActionPack(characterID: String) {
        guard starterActionPackCharacterID == characterID else { return }
        starterActionPackQueue.removeAll()
        let activeJobID = starterActionPackActiveJobID
        starterActionPackActiveJobID = nil
        starterActionPackCharacterID = nil
        if let activeJobID,
           let record = try? starterActionJobStore.record(jobID: activeJobID),
           record.characterID == characterID, record.canCancel {
            cancelStarterActionJob(
                jobID: activeJobID, characterID: characterID)
        } else {
            pushSettingsState()
        }
    }

    func startStarterActionJob(jobID: String, characterID: String,
                               quality: PetFinalGenerationQuality) {
        do {
            guard MimoSecret.openAI.isConfigured else {
                throw PetGenerationError.missingKey("OpenAI")
            }
            let original = try starterActionJobStore.record(jobID: jobID)
            guard original.characterID == characterID, original.canStart else {
                throw StarterActionJobError.invalidTransition
            }
            let context = try starterActionCanonicalContext(characterID: characterID)
            let firstRequestID = UUID().uuidString.lowercased()
            let needsProvider = original.completedBatches < original.estimatedProviderCalls
            if needsProvider,
               !reserveStarterActionProvider(requestID: firstRequestID, jobID: jobID) {
                return
            }
            do {
                let queued = try starterActionJobStore.queue(
                    jobID: jobID, requestID: firstRequestID,
                    quality: quality.rawValue)
                emitStarterActionJob(queued)
                if needsProvider {
                    runStarterActionBatch(
                        jobID: jobID, canonicalMaster: context.master,
                        personality: context.personality,
                        quality: quality, requestID: firstRequestID)
                } else {
                    let generating = try starterActionJobStore.markGenerating(
                        jobID: jobID, phase: "all-batches-checkpointed",
                        completedBatches: queued.completedBatches,
                        usedProviderCalls: queued.usedProviderCalls)
                    finishStarterActionLocally(
                        jobID: jobID, from: generating)
                }
            } catch {
                if needsProvider { releaseStudioGeneration(firstRequestID) }
                throw error
            }
        } catch {
            reportStarterActionError(
                jobID: jobID, error: error, code: "start_failed")
        }
    }

    private func runStarterActionBatch(jobID: String,
                                       canonicalMaster: Data,
                                       personality: String,
                                       quality: PetFinalGenerationQuality,
                                       requestID: String) {
        do {
            let record = try starterActionJobStore.record(jobID: jobID)
            guard record.state == .queued || record.state == .generating,
                  record.completedBatches < record.estimatedProviderCalls else {
                releaseStudioGeneration(requestID)
                throw StarterActionJobError.invalidTransition
            }
            let batchIndex = record.completedBatches
            let previous = batchIndex > 0
                ? try starterActionJobStore.batchData(
                    jobID: jobID, batchIndex: batchIndex - 1)
                : nil
            let generating = try starterActionJobStore.markGenerating(
                jobID: jobID,
                phase: "batch-\(batchIndex + 1)-of-\(record.estimatedProviderCalls)",
                completedBatches: record.completedBatches,
                usedProviderCalls: record.usedProviderCalls,
                requestID: requestID)
            emitStarterActionJob(generating)
            pushSettingsState()
            armStarterActionWatchdog(jobID: jobID, requestID: requestID)
            petGenerator.generateStarterActionBatch(
                requestID: requestID,
                actionID: generating.actionID,
                batchIndex: batchIndex,
                canonicalMasterData: canonicalMaster,
                previousBatchData: previous,
                styleBoardData: MimoStyleReference.requestData(),
                personalityVisual: personality,
                quality: quality,
                progress: { [weak self] phase, _, _ in
                    guard let self,
                          let current = try? self.starterActionJobStore.record(jobID: jobID),
                          current.state == .generating,
                          current.requestID == requestID else { return }
                    self.settingsCall("starterActionJobProgress", [
                        "jobID": jobID,
                        "phase": phase,
                        "completedBatches": current.completedBatches,
                        "estimatedProviderCalls": current.estimatedProviderCalls,
                    ])
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    self.disarmStarterActionWatchdog(requestID)
                    self.releaseStudioGeneration(requestID)
                    guard let current = try? self.starterActionJobStore.record(jobID: jobID),
                          current.state == .generating,
                          current.requestID == requestID else { return }
                    switch result {
                    case .failure(let error):
                        if let generation = error as? PetGenerationError,
                           generation.isCancellation {
                            return
                        }
                        let spent = current.usedProviderCalls
                            + (self.starterActionFailureMayHaveSpent(error) ? 1 : 0)
                        let failed = try? self.starterActionJobStore.markFailed(
                            jobID: jobID, code: "provider_failed",
                            message: self.starterActionDetail(error),
                            usedProviderCalls: min(
                                spent,
                                current.estimatedProviderCalls * current.maximumAttempts))
                        if let failed { self.emitStarterActionJob(failed) }
                        self.reportStarterActionError(
                            jobID: jobID, error: error, code: "provider_failed")
                        self.pushSettingsState()
                    case .success(let output):
                        do {
                            let completed = try self.starterActionJobStore.storeCompletedBatch(
                                jobID: jobID, batchIndex: batchIndex,
                                pngData: output.data,
                                usedProviderCalls: current.usedProviderCalls + 1)
                            self.emitStarterActionJob(completed)
                            self.pushSettingsState()
                            if completed.completedBatches
                                == completed.estimatedProviderCalls {
                                self.finishStarterActionLocally(
                                    jobID: jobID, from: completed)
                                return
                            }
                            let nextRequestID = UUID().uuidString.lowercased()
                            guard self.reserveStarterActionProvider(
                                requestID: nextRequestID, jobID: jobID) else {
                                let failed = try? self.starterActionJobStore.markFailed(
                                    jobID: jobID, code: "generation_in_progress",
                                    message: "The next saved batch is ready to resume; no extra request was sent.")
                                if let failed { self.emitStarterActionJob(failed) }
                                self.pushSettingsState()
                                return
                            }
                            self.runStarterActionBatch(
                                jobID: jobID, canonicalMaster: canonicalMaster,
                                personality: personality, quality: quality,
                                requestID: nextRequestID)
                        } catch {
                            let failed = try? self.starterActionJobStore.markFailed(
                                jobID: jobID, code: "checkpoint_failed",
                                message: self.starterActionDetail(error))
                            if let failed { self.emitStarterActionJob(failed) }
                            self.reportStarterActionError(
                                jobID: jobID, error: error,
                                code: "checkpoint_failed")
                            self.pushSettingsState()
                        }
                    }
                })
        } catch {
            disarmStarterActionWatchdog(requestID)
            releaseStudioGeneration(requestID)
            if let record = try? starterActionJobStore.record(jobID: jobID),
               record.state.isInFlight,
               let failed = try? starterActionJobStore.markFailed(
                jobID: jobID, code: "setup_failed",
                message: starterActionDetail(error)) {
                emitStarterActionJob(failed)
            }
            reportStarterActionError(
                jobID: jobID, error: error, code: "setup_failed")
            pushSettingsState()
        }
    }

    private func finishStarterActionLocally(jobID: String,
                                            from record: StarterActionJobRecord) {
        do {
            let local = try starterActionJobStore.markLocalProcessing(
                jobID: jobID, phase: "normalizing-family")
            emitStarterActionJob(local)
            pushSettingsState()
            processStarterActionLocally(jobID: jobID)
        } catch {
            if record.state.isInFlight,
               let failed = try? starterActionJobStore.markFailed(
                jobID: jobID, code: "local_setup_failed",
                message: starterActionDetail(error)) {
                emitStarterActionJob(failed)
            }
            reportStarterActionError(
                jobID: jobID, error: error, code: "local_setup_failed")
            pushSettingsState()
        }
    }

    private func processStarterActionLocally(jobID: String) {
        do {
            let local = try starterActionJobStore.record(jobID: jobID)
            guard local.state == .localProcessing else {
                throw StarterActionJobError.invalidTransition
            }
            let batches = try starterActionJobStore.completedBatchData(jobID: jobID)
            let definition = StarterActionCatalog.definition(local.actionID)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let processed = Result {
                    try ActionSheetProcessor.processCoherentBatches(
                        pngDatas: batches,
                        keepCounts: definition.batches.map(\.keepCount))
                }
                DispatchQueue.main.async {
                    guard let self,
                          let current = try? self.starterActionJobStore.record(jobID: jobID),
                          current.state == .localProcessing else { return }
                    do {
                        let sheet = try processed.get()
                        guard sheet.frames.count == definition.finalFrameCount,
                              let anchor = sheet.frames.first else {
                            throw ActionGenerationJobError.invalidStrip
                        }
                        let action = definition.manifestActionName
                        let metadata = ActionResultBundleMetadata(
                            schemaVersion: ActionResultBundleMetadata.schemaVersion,
                            action: action,
                            stripFilename: "action-\(action).png",
                            frameCount: definition.finalFrameCount,
                            cellSize: ActionSheetProcessor.outputCellSize,
                            framesPerSecond: definition.previewFramesPerSecond,
                            cycleDistanceCellPixels: nil,
                            anchorInCell: [
                                Double(anchor.anchorX), Double(anchor.anchorY),
                            ],
                            qaFilename: "action-\(action).qa.json",
                            automaticInstallAllowed: false)
                        let checker: [String: Any] = [
                            "schemaVersion": 1,
                            "hardPass": true,
                            "automaticInstallAllowed": false,
                            "manualReviewRequired": true,
                            "identityReviewRequired": true,
                            "actionID": definition.id.rawValue,
                            "frameCount": definition.finalFrameCount,
                            "providerCalls": current.usedProviderCalls,
                            "coherentBatchCount": definition.estimatedProviderCalls,
                        ]
                        let checkerData = try JSONSerialization.data(
                            withJSONObject: checker, options: [.sortedKeys])
                        let result = try self.actionGenerationJobStore.storeGeneratedResult(
                            characterID: current.characterID,
                            sourceLabel: "Mimo Starter · \(definition.titleEn)",
                            metadata: metadata,
                            stripData: sheet.pngData,
                            previewData: sheet.pngData,
                            checkerData: checkerData)
                        let review = try self.starterActionJobStore.markAwaitingReview(
                            jobID: jobID, resultJobID: result.id)
                        self.emitStarterActionJob(review)
                        self.settingsCall("actionJobImported", [
                            "job": self.actionGenerationJobStore.runtimeDictionary(for: result),
                        ])
                        self.pushSettingsState()
                    } catch {
                        let failed = try? self.starterActionJobStore.markFailed(
                            jobID: jobID, code: "local_processing_failed",
                            message: self.starterActionDetail(error))
                        if let failed { self.emitStarterActionJob(failed) }
                        self.reportStarterActionError(
                            jobID: jobID, error: error,
                            code: "local_processing_failed")
                        self.pushSettingsState()
                    }
                }
            }
        } catch {
            if let record = try? starterActionJobStore.record(jobID: jobID),
               record.state == .localProcessing,
               let failed = try? starterActionJobStore.markFailed(
                    jobID: jobID, code: "local_setup_failed",
                    message: starterActionDetail(error)) {
                emitStarterActionJob(failed)
            }
            reportStarterActionError(
                jobID: jobID, error: error, code: "local_setup_failed")
            pushSettingsState()
        }
    }

    func cancelStarterActionJob(jobID: String, characterID: String) {
        do {
            let record = try starterActionJobStore.record(jobID: jobID)
            guard record.characterID == characterID, record.canCancel else {
                throw StarterActionJobError.invalidTransition
            }
            if let requestID = record.requestID {
                petGenerator.cancel(requestID)
                disarmStarterActionWatchdog(requestID)
                releaseStudioGeneration(requestID)
            }
            let cancelled = try starterActionJobStore.cancel(jobID: jobID)
            emitStarterActionJob(cancelled)
            pushSettingsState()
        } catch {
            reportStarterActionError(
                jobID: jobID, error: error, code: "cancel_failed")
        }
    }

    // MARK: - Expression sheets (post-adoption blink/joy/rest frames)

    /// Sequentially generates one expression sheet per requested stage.
    /// Deliberately outside the studio ledger: adoption already succeeded, and
    /// each stage failing only costs that stage its expressions.
    func startExpressionRun(characterID: String, stagePNGs: [Data],
                            temperamentID: String, stages: [Int]) {
        guard expressionRunCharacterID == nil else {
            settingsCall("petExpressionError", [
                "characterID": characterID, "stageIndex": stages.first ?? 0,
                "code": "busy",
                "messageZh": "另一套表情正在生成，请稍候。",
                "messageEn": "Another expression run is in progress; try again soon.",
            ])
            return
        }
        let valid = stages.filter { (0..<stagePNGs.count).contains($0) }
        guard !valid.isEmpty else { return }
        expressionRunCharacterID = characterID
        stepExpressionRun(characterID: characterID, stagePNGs: stagePNGs,
                          temperamentID: temperamentID, remaining: valid,
                          total: valid.count, completed: 0)
    }

    /// Every exit from an expression run goes through here, so the run can
    /// never be left holding `expressionRunCharacterID`.
    private func endExpressionRun() {
        expressionRunWatchdog?.cancel()
        expressionRunWatchdog = nil
        expressionRunRequestID = nil
        expressionRunCharacterID = nil
    }

    private func armExpressionRunWatchdog(characterID: String, requestID: String) {
        expressionRunWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.expressionRunCharacterID == characterID,
                  self.expressionRunRequestID == requestID else { return }
            self.petGenerator.cancel(requestID)
            self.settingsCall("petExpressionError", [
                "characterID": characterID, "stageIndex": 0,
                "code": "timed_out",
                "messageZh": "表情生成超时，已停止。",
                "messageEn": "Expression generation timed out and was stopped.",
            ])
            self.endExpressionRun()
            self.pushSettingsState()
        }
        expressionRunWatchdog = watchdog
        DispatchQueue.main.asyncAfter(
            deadline: .now() + StudioGenerationLedger.reservationLifetime, execute: watchdog)
    }

    private func stepExpressionRun(characterID: String, stagePNGs: [Data],
                                   temperamentID: String, remaining: [Int],
                                   total: Int, completed: Int) {
        guard expressionRunCharacterID == characterID else { return }
        guard let stageIndex = remaining.first else {
            endExpressionRun()
            settingsCall("petExpressionDone", [
                "characterID": characterID, "completed": completed, "total": total,
            ])
            return
        }
        let rest = Array(remaining.dropFirst())
        let profile = CustomPetTemperaments.profile(for: temperamentID)
        let style = MimoStyleReference.requestData()
        // A plain UUID: petCancel parses its argument with UUID(uuidString:),
        // so the old "expr-<uuid>" form could never be matched and an in-flight
        // paid expression request was uncancellable.
        let requestID = UUID().uuidString.lowercased()
        expressionRunRequestID = requestID
        armExpressionRunWatchdog(characterID: characterID, requestID: requestID)
        let stageFrame = stagePNGs[stageIndex]
        let stageKinds: [PetEvolutionStage] = [.seed, .bloom, .radiant]
        let advance: (Bool) -> Void = { [weak self] succeeded in
            self?.stepExpressionRun(characterID: characterID, stagePNGs: stagePNGs,
                                    temperamentID: temperamentID, remaining: rest,
                                    total: total,
                                    completed: completed + (succeeded ? 1 : 0))
        }
        settingsCall("petExpressionProgress", [
            "characterID": characterID, "stageIndex": stageIndex,
            "phase": "generating", "completed": completed, "total": total,
        ])
        petGenerator.generateExpressionSheet(
            requestID: requestID, stage: stageKinds[stageIndex],
            stageFrameData: stageFrame,
            // No separate identity reference. This used to pass the same bytes
            // as stageFrameData, uploaded again as a second multipart part and
            // described to the model as an independent identity board — paid
            // image-input tokens for a duplicate, plus a misleading prompt.
            sourceDataURI: nil,
            styleBoardData: style,
            personalityVisual: profile.promptFragment,
            quality: .medium,
            progress: { [weak self] phase, _, _ in
                guard let self, self.expressionRunCharacterID == characterID else { return }
                self.settingsCall("petExpressionProgress", [
                    "characterID": characterID, "stageIndex": stageIndex,
                    "phase": phase, "completed": completed, "total": total,
                ])
            }, completion: { [weak self] result in
                guard let self, self.expressionRunCharacterID == characterID else { return }
                switch result {
                case .failure(let error):
                    // Cancellation ends the run rather than marching on to the
                    // next stage and spending again.
                    if let generationError = error as? PetGenerationError,
                       generationError.isCancellation {
                        self.endExpressionRun()
                        self.settingsCall("petExpressionCancelled", ["characterID": characterID])
                        return
                    }
                    self.settingsCall("petExpressionError", [
                        "characterID": characterID, "stageIndex": stageIndex,
                        "code": "provider_failed",
                        "messageZh": "第 \(stageIndex + 1) 段的表情生成失败：\(error.localizedDescription)",
                        "messageEn": "Expressions for form \(stageIndex + 1) failed: \(error.localizedDescription)",
                    ])
                    advance(false)
                case .success(let output):
                    self.installExpressionSheet(characterID: characterID,
                                                stageIndex: stageIndex,
                                                rawPNG: output.data,
                                                completed: completed, total: total,
                                                requestID: requestID,
                                                advance: advance)
                }
            }
        )
    }

    private func installExpressionSheet(characterID: String, stageIndex: Int,
                                        rawPNG: Data, completed: Int, total: Int,
                                        requestID: String,
                                        salvageNearEdge: Bool = false,
                                        advance: @escaping (Bool) -> Void) {
        settingsCall("petExpressionProgress", [
            "characterID": characterID, "stageIndex": stageIndex,
            "phase": "processing", "completed": completed, "total": total,
        ])
        // The image is already paid for. Retain it before local processing can
        // reject it, exactly as the studio paths do — this run used to drop
        // `rawPNG` on the floor with no recovery at all.
        if !salvageNearEdge {
            _ = retainRaw(rawPNG, requestID: requestID, phase: .expressionSheet,
                          quality: PetFinalGenerationQuality.medium.rawValue,
                          providerSeconds: 0)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try CharacterSheetProcessor.process(pngData: rawPNG,
                                                    allowNearEdgeRecovery: salvageNearEdge)
            }
            DispatchQueue.main.async {
                guard let self, self.expressionRunCharacterID == characterID else { return }
                do {
                    let sheet = try result.get()
                    let spec = try self.customPetStore.installExpressionSheet(
                        characterID: characterID, stageIndex: stageIndex,
                        pngData: sheet.pngData)
                    if JSONSerialization.isValidJSONObject(spec),
                       let data = try? JSONSerialization.data(withJSONObject: spec),
                       let json = String(data: data, encoding: .utf8) {
                        let isCurrent = UserDefaults.standard.string(forKey: "character") == characterID
                        self.js("famRegisterCustomPet(\(json), \(isCurrent))")
                        self.settingsCall("petExpressionResult", [
                            "characterID": characterID, "stageIndex": stageIndex,
                            "spec": spec, "completed": completed + 1, "total": total,
                        ])
                        self.pushSettingsState()
                    }
                    _ = try? self.generationDraftStore.delete(requestID: requestID)
                    advance(true)
                } catch {
                    // The same near-edge layout deviation the studio paths treat
                    // as salvageable used to burn a paid generation here.
                    if !salvageNearEdge, self.canSalvageNearEdge(error) {
                        self.installExpressionSheet(
                            characterID: characterID, stageIndex: stageIndex,
                            rawPNG: rawPNG, completed: completed, total: total,
                            requestID: requestID, salvageNearEdge: true, advance: advance)
                        return
                    }
                    self.settingsCall("petExpressionError", [
                        "characterID": characterID, "stageIndex": stageIndex,
                        "code": "local_failed",
                        "providerCompleted": true,
                        "outputRetained": self.retainedDraftExists(requestID),
                        "messageZh": "第 \(stageIndex + 1) 段的表情处理失败：\(error.localizedDescription)",
                        "messageEn": "Expressions for form \(stageIndex + 1) could not be processed: \(error.localizedDescription)",
                    ])
                    advance(false)
                }
            }
        }
    }

    private func startEvolutionGeneration(requestID: String,
                                          candidateDraftID: String,
                                          candidate: PendingCandidateBoardDraft,
                                          candidateIndex: Int,
                                          styleTuningNote: String,
                                          quality: PetFinalGenerationQuality) {
        guard reserveProviderGeneration(requestID) else { return }
        let startedAt = Date()
        let master = candidate.candidatePNGs[candidateIndex]
        let profile = CustomPetTemperaments.profile(for: candidate.temperamentID)
        let style = MimoStyleReference.requestData()
        petGenerator.generateFinalEvolutionSheet(
            requestID: requestID, masterData: master,
            sourceDataURI: candidate.sourceDataURI,
            styleBoardData: style,
            referenceEvidenceJSON: candidate.referenceEvidenceJSON,
            styleTuningNote: styleTuningNote,
            personalityVisual: profile.promptFragment,
            likeness: candidate.likeness, quality: quality,
            progress: { [weak self] phase, partial, _ in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                self.studioProgress(requestID: requestID, phase: phase,
                                    startedAt: startedAt, partial: partial)
            }, completion: { [weak self] result in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .failure(let error):
                    self.studioProviderError(requestID: requestID, error: error,
                                             startedAt: startedAt, phase: "evolution")
                case .success(let output):
                    let providerSeconds = Date().timeIntervalSince(startedAt)
                    let retained = self.retainRaw(
                        output.data, requestID: requestID, phase: .evolution,
                        quality: quality.rawValue, providerSeconds: providerSeconds)
                    let recovery = EvolutionGenerationRecovery(
                        rawPNG: output.data, masterPNG: master,
                        sourceDataURI: candidate.sourceDataURI,
                        referenceEvidenceJSON: candidate.referenceEvidenceJSON,
                        styleTuningNote: styleTuningNote,
                        temperamentID: candidate.temperamentID,
                        likeness: candidate.likeness, quality: quality,
                        providerSeconds: providerSeconds, usage: output.usage,
                        candidateDraftID: candidateDraftID,
                        styleBoardUsed: style != nil, createdAt: Date())
                    self.pendingLocalRecoveries[requestID] = .evolution(recovery)
                    self.processEvolutionGeneration(requestID: requestID,
                                                    recovery: recovery,
                                                    outputRetained: retained)
                }
            }
        )
    }

    private func processEvolutionGeneration(requestID: String,
                                            recovery: EvolutionGenerationRecovery,
                                            outputRetained: Bool,
                                            salvageNearEdge: Bool = false) {
        let localStartedAt = Date()
        studioProgress(requestID: requestID, phase: "processing",
                       startedAt: localStartedAt,
                       providerSeconds: recovery.providerSeconds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try CharacterSheetProcessor.process(
                    pngData: recovery.rawPNG,
                    allowNearEdgeRecovery: salvageNearEdge)
            }
            let localSeconds = Date().timeIntervalSince(localStartedAt)
            DispatchQueue.main.async {
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .success(let sheet):
                    var warnings = self.boundaryWarnings(sheet.quality)
                    if !recovery.styleBoardUsed {
                        warnings.append([
                            "zh": "内置米墨风格板没有载入；这次使用了主角图与文字风格约束。",
                            "en": "The bundled Mimo style board was unavailable; master and prompt styling were used.",
                        ])
                    }
                    // markProcessed wrote a multi-megabyte processed.png that
                    // the very next line deleted along with the directory.
                    _ = try? self.generationDraftStore.delete(requestID: requestID)
                    self.pendingEvolutionSheets[requestID] = PendingEvolutionSheetDraft(
                        pngData: sheet.pngData, stagePNGs: sheet.stagePNGs,
                        masterPNG: recovery.masterPNG,
                        sourceDataURI: recovery.sourceDataURI,
                        referenceEvidenceJSON: recovery.referenceEvidenceJSON,
                        styleTuningNote: recovery.styleTuningNote,
                        temperamentID: recovery.temperamentID,
                        likeness: recovery.likeness, quality: recovery.quality,
                        stageQualities: Array(repeating: recovery.quality, count: 3),
                        lastTouchedAt: Date(),
                        relatedRequestIDs: [recovery.candidateDraftID, requestID])
                    self.visibleEvolutionDraftID = requestID
                    self.pendingLocalRecoveries.removeValue(forKey: requestID)
                    self.settingsCall("petEvolutionResult", [
                        "requestID": requestID,
                        "draftID": requestID,
                        "sheet": PetGenerationCoordinator.dataURI(sheet.pngData),
                        "quality": recovery.quality.rawValue,
                        "providerSeconds": recovery.providerSeconds,
                        "localSeconds": localSeconds,
                        "warnings": warnings,
                        "usage": recovery.usage.dictionary,
                        "model": "gpt-image-2", "size": "1536x1024",
                        "partialImages": 1,
                        "styleBoardUsed": recovery.styleBoardUsed,
                        "referenceCount": recovery.styleBoardUsed ? 3 : 2,
                        "generationRecoveryCount": self.generationDraftStore.recoverableDraftCount(),
                    ])
                    self.releaseStudioGeneration(requestID)
                    self.announceStudioBackground(requestID, kind: "success", "三段成长图已经做好，打开设置可以预览或带回桌面。", "The three-form evolution is ready; open Settings to preview or install it.")
                case .failure(let error):
                    let canRetry = !salvageNearEdge && self.canSalvageNearEdge(error)
                    if !canRetry { self.pendingLocalRecoveries.removeValue(forKey: requestID) }
                    self.studioLocalError(
                        requestID: requestID, error: error, rawPNG: recovery.rawPNG,
                        providerSeconds: recovery.providerSeconds,
                        localSeconds: localSeconds, outputRetained: outputRetained,
                        canRetryLocally: canRetry)
                }
            }
        }
    }

    private func startStageRegeneration(requestID: String, parentDraftID: String,
                                        stage: PetEvolutionStage,
                                        evolution: PendingEvolutionSheetDraft,
                                        styleTuningNote: String,
                                        quality: PetFinalGenerationQuality) {
        guard reserveProviderGeneration(requestID) else { return }
        activeStageParents[requestID] = parentDraftID
        if var stored = pendingEvolutionSheets[parentDraftID] {
            stored.lastTouchedAt = Date()
            pendingEvolutionSheets[parentDraftID] = stored
        }
        let startedAt = Date()
        let profile = CustomPetTemperaments.profile(for: evolution.temperamentID)
        let style = MimoStyleReference.requestData()
        petGenerator.regenerateEvolutionStage(
            requestID: requestID, stage: stage,
            currentSheetData: evolution.pngData, masterData: evolution.masterPNG,
            sourceDataURI: evolution.sourceDataURI,
            styleBoardData: style,
            referenceEvidenceJSON: evolution.referenceEvidenceJSON,
            styleTuningNote: styleTuningNote,
            personalityVisual: profile.promptFragment, likeness: evolution.likeness,
            quality: quality,
            progress: { [weak self] phase, partial, _ in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                self.studioProgress(requestID: requestID, phase: phase,
                                    startedAt: startedAt, partial: partial)
            }, completion: { [weak self] result in
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .failure(let error):
                    self.studioProviderError(requestID: requestID, error: error,
                                             startedAt: startedAt, phase: "replacement")
                case .success(let output):
                    let providerSeconds = Date().timeIntervalSince(startedAt)
                    let retained = self.retainRaw(
                        output.data, requestID: requestID, phase: .replacement,
                        quality: quality.rawValue,
                        providerSeconds: providerSeconds)
                    let recovery = StageGenerationRecovery(
                        rawPNG: output.data, parentDraftID: parentDraftID,
                        stage: stage, quality: quality,
                        styleTuningNote: styleTuningNote,
                        providerSeconds: providerSeconds,
                        usage: output.usage, styleBoardUsed: style != nil,
                        createdAt: Date())
                    self.pendingLocalRecoveries[requestID] = .replacement(recovery)
                    self.processStageGeneration(requestID: requestID,
                                                recovery: recovery,
                                                outputRetained: retained)
                }
            }
        )
    }

    private func processStageGeneration(requestID: String,
                                        recovery: StageGenerationRecovery,
                                        outputRetained: Bool,
                                        salvageNearEdge: Bool = false) {
        guard let parent = pendingEvolutionSheets[recovery.parentDraftID] else {
            activeStageParents.removeValue(forKey: requestID)
            pendingLocalRecoveries.removeValue(forKey: requestID)
            studioLocalError(
                requestID: requestID,
                error: PetGenerationError.provider("The evolution preview expired before the replacement could be merged."),
                rawPNG: recovery.rawPNG, providerSeconds: recovery.providerSeconds,
                localSeconds: 0, outputRetained: outputRetained,
                canRetryLocally: false)
            return
        }
        let localStartedAt = Date()
        studioProgress(requestID: requestID, phase: "processing",
                       startedAt: localStartedAt,
                       providerSeconds: recovery.providerSeconds)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> (Data, Data, Bool) in
                guard let kind = CharacterSheetStageKind(rawValue: recovery.stage.rawValue) else {
                    throw CharacterSheetProcessingError.unreadableImage
                }
                let replacement = try CharacterSheetProcessor.processSingleStage(
                    pngData: recovery.rawPNG, kind: kind,
                    allowNearEdgeRecovery: salvageNearEdge)
                let sheet = try CharacterSheetProcessor.replaceStage(
                    in: parent.pngData, kind: kind,
                    with: replacement.stage.pngData)
                return (sheet, replacement.stage.pngData, replacement.recoveredNearEdge)
            }
            let localSeconds = Date().timeIntervalSince(localStartedAt)
            DispatchQueue.main.async {
                guard let self, self.studioGenerationLedger.activeRequestID == requestID else { return }
                switch result {
                case .success(let (sheet, stagePNG, recoveredNearEdge)):
                    if outputRetained {
                        _ = try? self.generationDraftStore.markProcessed(
                            requestID: requestID, pngData: sheet,
                            localSeconds: localSeconds)
                    }
                    guard var updated = self.pendingEvolutionSheets[recovery.parentDraftID] else {
                        self.pendingLocalRecoveries.removeValue(forKey: requestID)
                        self.studioLocalError(
                            requestID: requestID,
                            error: PetGenerationError.provider("The evolution preview expired before the replacement could be merged."),
                            rawPNG: recovery.rawPNG,
                            providerSeconds: recovery.providerSeconds,
                            localSeconds: localSeconds,
                            outputRetained: outputRetained,
                            canRetryLocally: false)
                        return
                    }
                    _ = try? self.generationDraftStore.delete(requestID: requestID)
                    updated.pngData = sheet
                    updated.stagePNGs[recovery.stage.sheetIndex] = stagePNG
                    updated.stageQualities[recovery.stage.sheetIndex] = recovery.quality
                    updated.styleTuningNote = recovery.styleTuningNote
                    updated.lastTouchedAt = Date()
                    if !updated.relatedRequestIDs.contains(requestID) {
                        updated.relatedRequestIDs.append(requestID)
                    }
                    self.pendingEvolutionSheets[recovery.parentDraftID] = updated
                    self.visibleEvolutionDraftID = recovery.parentDraftID
                    self.activeStageParents.removeValue(forKey: requestID)
                    self.pendingLocalRecoveries.removeValue(forKey: requestID)
                    var warnings: [[String: String]] = []
                    if recoveredNearEdge {
                        warnings.append([
                            "zh": "这个形态很靠近画布，但仍有完整边距；已用安全恢复模式提取。",
                            "en": "Recovered this complete form from a narrow but nonzero canvas margin.",
                        ])
                    }
                    if !recovery.styleBoardUsed {
                        warnings.append([
                            "zh": "内置米墨风格板没有载入；这次依据现有成长图保持风格。",
                            "en": "The bundled Mimo style board was unavailable; existing-sheet styling was used.",
                        ])
                    }
                    self.settingsCall("petStageResult", [
                        "requestID": requestID,
                        "draftID": recovery.parentDraftID,
                        "stageIndex": recovery.stage.sheetIndex,
                        "quality": recovery.quality.rawValue,
                        "sheet": PetGenerationCoordinator.dataURI(sheet),
                        "stageImage": PetGenerationCoordinator.dataURI(stagePNG),
                        "providerSeconds": recovery.providerSeconds,
                        "localSeconds": localSeconds,
                        "warnings": warnings,
                        "usage": recovery.usage.dictionary,
                        "model": "gpt-image-2", "size": "1024x1024",
                        "partialImages": 1,
                        "styleBoardUsed": recovery.styleBoardUsed,
                        "referenceCount": recovery.styleBoardUsed ? 4 : 3,
                        "generationRecoveryCount": self.generationDraftStore.recoverableDraftCount(),
                    ])
                    self.releaseStudioGeneration(requestID)
                    self.announceStudioBackground(requestID, kind: "success", "这一段已经重画完成，另外两段保持不变。", "That form is redrawn; the other two are unchanged.")
                case .failure(let error):
                    let canRetry = !salvageNearEdge && self.canSalvageNearEdge(error)
                    if !canRetry { self.pendingLocalRecoveries.removeValue(forKey: requestID) }
                    self.studioLocalError(
                        requestID: requestID, error: error, rawPNG: recovery.rawPNG,
                        providerSeconds: recovery.providerSeconds,
                        localSeconds: localSeconds, outputRetained: outputRetained,
                        canRetryLocally: canRetry)
                }
            }
        }
    }

    private func retryLocalGeneration(_ requestID: String) {
        guard let recovery = pendingLocalRecoveries[requestID] else {
            settingsCall("petStudioError", [
                "requestID": requestID,
                "kind": "local",
                "phase": "recovery",
                "message": voice("这份本地恢复稿已过期", "This local recovery draft expired"),
                "outputRetained": false,
            ])
            return
        }
        guard reserveLocalProcessing(requestID) else {
            // Every other rejection path emits a petStudioError; this one left
            // the panel sitting there after the user clicked "retry locally".
            settingsCall("petStudioError", [
                "requestID": requestID, "kind": "setup", "phase": "input",
                "code": "generation_in_progress",
                "messageZh": "另一项生成正在进行，或这次结果已经过期，无法在本机重试。",
                "messageEn": "Another generation is in progress, or this result has expired and can no longer be reprocessed locally.",
                "requestNotStarted": true, "outputRetained": retainedDraftExists(requestID),
            ])
            return
        }
        switch recovery {
        case .candidates(let context):
            processCandidateGeneration(requestID: requestID, recovery: context,
                                       outputRetained: retainedDraftExists(requestID),
                                       salvageNearEdge: true)
        case .evolution(let context):
            processEvolutionGeneration(requestID: requestID, recovery: context,
                                       outputRetained: retainedDraftExists(requestID),
                                       salvageNearEdge: true)
        case .replacement(let context):
            activeStageParents[requestID] = context.parentDraftID
            processStageGeneration(requestID: requestID, recovery: context,
                                   outputRetained: retainedDraftExists(requestID),
                                   salvageNearEdge: true)
        }
    }

    func handleSettings(_ body: [String: Any]) {
        let d = UserDefaults.standard
        switch body["type"] as? String ?? "" {
        case "pick":
            if let id = body["id"] as? String {
                let builtins: Set<String> = ["lulu", "clawd", "nat"]
                let allowed = builtins.contains(id)
                    || (id == "prototype" && storedCustomPetSpec() != nil)
                    || (try? customPetStore.runtimeSpec(characterID: id)) != nil
                if allowed {
                    js("famSetCharacter(\(jsonStr(id)))")
                    d.set(id, forKey: "character")
                    refreshNativeCompanion()
                }
            }
        case "petPrototype":
            if let spec = body["spec"] as? [String: Any],
               validGeneratedPetSpec(spec),
               JSONSerialization.isValidJSONObject(spec),
               let data = try? JSONSerialization.data(withJSONObject: spec),
               let json = String(data: data, encoding: .utf8) {
                d.set(json, forKey: "customPetSpec")
                d.set("prototype", forKey: "character")
                js("famSetPrototypePet(\(json))")
                refreshNativeCompanion()
                revealOverlay()
            }
        case "petUpload":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image]
            panel.message = voice("最多选择 8 张同一主角的多角度参考", "Choose up to 8 views of the same subject")
            if panel.runModal() == .OK {
                // Each image is decoded, downsampled to 2048px, re-encoded as
                // JPEG, and base64'd. Eight large screenshots is seconds of
                // work and eight ~28MB strings live at once — it beachballed
                // when it ran inline on the main thread.
                let urls = Array(panel.urls.prefix(8))
                for url in urls {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let uri = petReferenceDataURI(url)
                        let name = url.deletingPathExtension().lastPathComponent
                        DispatchQueue.main.async {
                            guard let self else { return }
                            guard let uri else {
                                self.settingsCall("petStudioError", [
                                    "kind": "setup", "phase": "input", "code": "invalid_reference",
                                    "messageZh": "有一张图片太大、尺寸异常或无法读取；已跳过它。请选择 20 MB 以内的 PNG、JPEG 或 WebP。",
                                    "messageEn": "One image was too large, had unsafe dimensions, or could not be read, so it was skipped. Choose PNG, JPEG, or WebP under 20 MB.",
                                    "requestNotStarted": true, "outputRetained": false,
                                ])
                                return
                            }
                            self.settingsWeb?.evaluateJavaScript(
                                "loadPetImageData(\(jsonStr(uri)), \(jsonStr(name)), {append:true})",
                                completionHandler: nil)
                        }
                    }
                }
            }
        case "petStarterActionStartDefaults":
            guard let characterID = activeCustomCharacterID(
                    requested: body["characterID"]) else {
                reportStarterActionError(
                    jobID: nil,
                    error: StarterActionJobError.invalidCharacterID,
                    code: "invalid_character")
                return
            }
            startStarterActionPack(
                characterID: characterID,
                quality: PetFinalGenerationQuality.resolve(
                    body["quality"] as? String))
        case "petStarterActionCancelDefaults":
            guard let characterID = activeCustomCharacterID(
                    requested: body["characterID"]) else {
                reportStarterActionError(
                    jobID: nil,
                    error: StarterActionJobError.invalidCharacterID,
                    code: "invalid_character")
                return
            }
            cancelStarterActionPack(characterID: characterID)
        case "petStarterActionStart":
            guard let characterID = activeCustomCharacterID(
                    requested: body["characterID"]),
                  let jobID = body["jobID"] as? String else {
                reportStarterActionError(
                    jobID: body["jobID"] as? String,
                    error: StarterActionJobError.invalidCharacterID,
                    code: "invalid_character")
                return
            }
            startStarterActionJob(
                jobID: jobID,
                characterID: characterID,
                quality: PetFinalGenerationQuality.resolve(
                    body["quality"] as? String))
        case "petStarterActionCancel":
            guard let characterID = activeCustomCharacterID(
                    requested: body["characterID"]),
                  let jobID = body["jobID"] as? String else {
                reportStarterActionError(
                    jobID: body["jobID"] as? String,
                    error: StarterActionJobError.invalidCharacterID,
                    code: "invalid_character")
                return
            }
            cancelStarterActionJob(jobID: jobID, characterID: characterID)
        case "petStarterActionReprocess":
            guard let characterID = activeCustomCharacterID(
                    requested: body["characterID"]),
                  let jobID = body["jobID"] as? String else {
                reportStarterActionError(
                    jobID: body["jobID"] as? String,
                    error: StarterActionJobError.invalidCharacterID,
                    code: "invalid_character")
                return
            }
            do {
                let record = try starterActionJobStore.record(jobID: jobID)
                guard record.characterID == characterID else {
                    throw StarterActionJobError.invalidCharacterID
                }
                let local = try starterActionJobStore.beginLocalReprocess(
                    jobID: jobID)
                emitStarterActionJob(local)
                pushSettingsState()
                processStarterActionLocally(jobID: jobID)
            } catch {
                reportStarterActionError(
                    jobID: jobID, error: error, code: "local_reprocess_failed")
            }
        case "petActionImport":
            guard let characterID = activeCustomCharacterID(requested: body["characterID"]) else {
                reportActionJobError(ActionGenerationJobError.invalidCharacterID,
                                     code: "invalid_character")
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.folder]
            panel.prompt = voice("导入结果", "Import Result")
            panel.message = voice(
                "选择包含 action-walk.png、metadata、QA 和 contact sheet 的 Wan 结果文件夹",
                "Choose the Wan result folder containing the action strip, metadata, QA, and contact sheet")
            guard panel.runModal() == .OK, let source = panel.url else { return }
            settingsCall("actionJobImportStarted", [:])
            let scoped = source.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                do {
                    let record = try self.actionGenerationJobStore.importResultBundle(
                        at: source, characterID: characterID)
                    let job = self.actionGenerationJobStore.runtimeDictionary(for: record)
                    DispatchQueue.main.async {
                        self.settingsCall("actionJobImported", ["job": job])
                        self.pushSettingsState()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.reportActionJobError(error, code: "import_failed")
                    }
                }
            }
        case "petActionPreview":
            guard let characterID = activeCustomCharacterID(requested: body["characterID"]),
                  let jobID = body["jobID"] as? String else {
                reportActionJobError(ActionGenerationJobError.invalidCharacterID,
                                     code: "invalid_character")
                return
            }
            do {
                let record = try actionGenerationJobStore.record(jobID: jobID)
                guard record.characterID == characterID else {
                    throw ActionGenerationJobError.invalidCharacterID
                }
                let strip = try actionGenerationJobStore.stripData(jobID: record.id)
                let anchor = record.metadata.anchorInCell.flatMap { value -> CGPoint? in
                    guard value.count == 2 else { return nil }
                    return CGPoint(x: CGFloat(value[0]), y: CGFloat(value[1]))
                }
                guard let sprite = CompanionSprite.load(
                    data: strip, semantics: .actionPoses, fixedAnchorInCell: anchor) else {
                    throw ActionGenerationJobError.invalidStrip
                }
                let playback = CompanionActionPlaybackSpec(
                    framesPerSecond: CGFloat(record.metadata.framesPerSecond),
                    cycleDistanceInCellPixels: record.metadata.cycleDistanceCellPixels.map {
                        CGFloat($0)
                    },
                    frameDurationsSeconds: record.metadata.action == "rest"
                        && sprite.frameCount == 6
                        ? StarterActionCatalog.definition(.sleep)
                            .frameDurations.map { CGFloat($0) }
                        : nil,
                    loopStartFrame: record.metadata.action == "rest"
                        && sprite.frameCount == 6 ? 3 : nil)
                guard companionRuntime.previewExternalAction(
                    named: record.metadata.action, sprite: sprite,
                    playbackSpec: playback) else {
                    throw ActionGenerationJobError.missingJob
                }
                revealOverlay()
                settingsCall("actionJobPreviewing", ["jobID": record.id])
            } catch {
                reportActionJobError(error, code: "preview_failed")
            }
        case "petActionAccept":
            guard let characterID = activeCustomCharacterID(requested: body["characterID"]),
                  let jobID = body["jobID"] as? String else {
                reportActionJobError(ActionGenerationJobError.invalidCharacterID,
                                     code: "invalid_character")
                return
            }
            do {
                let record = try actionGenerationJobStore.record(jobID: jobID)
                guard record.characterID == characterID else {
                    throw ActionGenerationJobError.invalidCharacterID
                }
                // Fail closed: the external tool can never auto-authorize an
                // install, and manual Accept is enabled only after hard QA.
                guard record.isEligibleForManualInstall else {
                    throw ActionGenerationJobError.invalidChecker
                }
                let strip = try actionGenerationJobStore.stripData(jobID: record.id)
                let anchor = record.metadata.anchorInCell.flatMap { value -> CGPoint? in
                    guard value.count == 2 else { return nil }
                    return CGPoint(x: CGFloat(value[0]), y: CGFloat(value[1]))
                }
                let spec = try customPetStore.installActionStrip(
                    characterID: characterID,
                    action: record.metadata.action,
                    pngData: strip,
                    framesPerSecond: record.metadata.framesPerSecond,
                    cycleDistance: record.metadata.cycleDistanceCellPixels,
                    anchorInCell: anchor)
                let installedRecord = (try? actionGenerationJobStore.markInstalled(
                    jobID: record.id)) ?? record
                if let starter = starterActionJobStore.jobs(characterID: characterID)
                    .first(where: { $0.resultJobID == record.id }),
                   let installedStarter = try? starterActionJobStore.markInstalled(
                    jobID: starter.id) {
                    emitStarterActionJob(installedStarter)
                }
                if JSONSerialization.isValidJSONObject(spec),
                   let data = try? JSONSerialization.data(withJSONObject: spec),
                   let json = String(data: data, encoding: .utf8) {
                    js("famSetCustomPet(\(json), false)")
                }
                refreshNativeCompanion()
                _ = companionRuntime.previewAction(named: record.metadata.action)
                settingsCall("actionJobAccepted", [
                    "job": actionGenerationJobStore.runtimeDictionary(for: installedRecord),
                    "spec": spec,
                ])
                pushSettingsState()
                revealOverlay()
            } catch {
                reportActionJobError(error, code: "accept_failed")
            }
        case "petSaveKeys":
            var failed: [String] = []
            if let value = body["pixelLab"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !MimoSecret.pixelLab.write(value) { failed.append("PixelLab") }
            }
            if let value = body["openAI"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !MimoSecret.openAI.write(value) { failed.append("OpenAI") }
            }
            var keyState: [String: Any] = [
                "pixelLabConfigured": MimoSecret.pixelLab.isConfigured,
                "openAIConfigured": MimoSecret.openAI.isConfigured,
            "openAIKeySource": MimoSecret.openAI.source.rawValue,
            ]
            if !failed.isEmpty {
                keyState["failed"] = failed
                keyState["error"] = voice("无法安全保存：\(failed.joined(separator: ", "))", "Could not save securely: \(failed.joined(separator: ", "))")
            }
            settingsCall("petKeysSaved", keyState)
        case "petClearKey":
            let provider = body["provider"] as? String == "openai" ? "OpenAI" : "PixelLab"
            let cleared = provider == "OpenAI" ? MimoSecret.openAI.write("") : MimoSecret.pixelLab.write("")
            var keyState: [String: Any] = [
                "pixelLabConfigured": MimoSecret.pixelLab.isConfigured,
                "openAIConfigured": MimoSecret.openAI.isConfigured,
            "openAIKeySource": MimoSecret.openAI.source.rawValue,
                "cleared": provider,
            ]
            if !cleared { keyState["error"] = voice("无法清除 \(provider)", "Could not clear \(provider)") }
            settingsCall("petKeysSaved", keyState)
        case "petConfirmReferences":
            guard let requestID = generationRequestID(body["requestID"]),
                  studioGenerationLedger.activeRequestID == requestID,
                  let prepared = pendingReferencePreflights.removeValue(forKey: requestID) else {
                settingsCall("petStudioError", [
                    "requestID": body["requestID"] as? String ?? "",
                    "kind": "setup", "phase": "input",
                    "code": "reference_preview_expired",
                    "messageZh": "这张身份板已过期；没有调用 OpenAI。请重新检查参考图。",
                    "messageEn": "This identity-board preview expired. OpenAI was not called; review the references again.",
                    "outputRetained": false, "requestNotStarted": true,
                ])
                return
            }
            let confirmedStyleTuningNote = (body["styleTuningNote"] as? String).map {
                PetVisualTuningNote.sanitize($0)
            } ?? prepared.styleTuningNote
            startCandidateGeneration(
                requestID: requestID,
                source: prepared.sourceDataURI,
                referenceEvidenceJSON: prepared.referenceEvidenceJSON,
                styleTuningNote: confirmedStyleTuningNote,
                profile: prepared.profile, likeness: prepared.likeness,
                alreadyReserved: true)
        case "petCancel":
            if let rawID = body["requestID"] as? String,
               let uuid = UUID(uuidString: rawID) {
                let id = uuid.uuidString.lowercased()
                petGenerator.cancel(id)
                pendingReferencePreflights.removeValue(forKey: id)
                pendingCandidateBoards.removeValue(forKey: id)
                if let evolution = pendingEvolutionSheets.removeValue(forKey: id) {
                    for relatedID in evolution.relatedRequestIDs {
                        _ = try? generationDraftStore.delete(requestID: relatedID)
                    }
                }
                pendingLocalRecoveries.removeValue(forKey: id)
                activeStageParents.removeValue(forKey: id)
                backgroundStudioRequests.remove(id)
                if visibleCandidateDraftID == id { visibleCandidateDraftID = nil }
                if visibleEvolutionDraftID == id { visibleEvolutionDraftID = nil }
                _ = try? generationDraftStore.delete(requestID: id)
                // An expression run is now a plain UUID too, so cancel reaches it.
                if expressionRunRequestID == id { endExpressionRun() }
                releaseStudioGeneration(id)
                settingsCall("petGenerationCancelled", [
                    "generationRecoveryCount": generationDraftStore.recoverableDraftCount(),
                ])
            }
        case "petQuality":
            let quality = PetFinalGenerationQuality.resolve(body["quality"] as? String)
            d.set(quality.rawValue, forKey: "petImageQuality")
        case "petVisibleDrafts":
            if let raw = body["draftID"] as? String,
               let id = generationRequestID(raw), pendingEvolutionSheets[id] != nil {
                visibleEvolutionDraftID = id
            } else {
                visibleEvolutionDraftID = nil
            }
            if let raw = body["candidateDraftID"] as? String,
               let id = generationRequestID(raw), pendingCandidateBoards[id] != nil {
                visibleCandidateDraftID = id
            } else {
                visibleCandidateDraftID = nil
            }
            touchVisibleStudioDrafts()
        case "petGenerateCandidates":
            pruneStudioState()
            guard let requestID = generationRequestID(body["requestID"]),
                  let inputs = petReferenceInputs(body) else {
                settingsCall("petStudioError", [
                    "requestID": body["requestID"] as? String ?? "",
                    "kind": "setup", "phase": "input", "code": "invalid_reference",
                    "messageZh": "参考集无效、重复、过大或超过 8 张；没有调用 OpenAI，也不会产生费用。",
                    "messageEn": "The reference set was invalid, duplicated, too large, or exceeded 8 images. OpenAI was not called and no cost was incurred.",
                    "outputRetained": false, "requestNotStarted": true,
                    "resetTo": "upload",
                ])
                return
            }
            let profile = CustomPetTemperaments.profile(
                for: body["temperamentID"] as? String)
            let likeness = max(0, min(1, body["likeness"] as? Double ?? 0.58))
            let styleTuningNote = PetVisualTuningNote.sanitize(
                body["styleTuningNote"] as? String)
            let useDetectedPersonDefault = !(body["styleTuningCustomized"] as? Bool ?? false)
            prepareCandidateGeneration(requestID: requestID, inputs: inputs,
                                       profile: profile, likeness: likeness,
                                       styleTuningNote: styleTuningNote,
                                       useDetectedPersonDefault: useDetectedPersonDefault)
        case "petGenerateEvolution":
            pruneStudioState()
            guard let requestID = generationRequestID(body["requestID"]),
                  let candidateDraftID = generationRequestID(body["candidateDraftID"]),
                  let candidate = pendingCandidateBoards[candidateDraftID],
                  let index = (body["candidateIndex"] as? NSNumber)?.intValue,
                  candidate.candidatePNGs.indices.contains(index) else {
                settingsCall("petStudioError", [
                    "requestID": body["requestID"] as? String ?? "",
                    "kind": "setup", "phase": "input", "code": "candidate_expired",
                    "messageZh": "候选稿已过期；米墨没有发出新的付费请求。请重新生成 Low 草稿。",
                    "messageEn": "The candidate draft expired; Mimo did not submit a paid request. Generate new Low drafts.",
                    "outputRetained": false, "requestNotStarted": true,
                    "resetTo": "candidates",
                ])
                return
            }
            let quality = PetFinalGenerationQuality.resolve(body["quality"] as? String)
            let styleTuningNote = (body["styleTuningNote"] as? String).map {
                PetVisualTuningNote.sanitize($0)
            } ?? candidate.styleTuningNote
            d.set(quality.rawValue, forKey: "petImageQuality")
            if var refreshed = pendingCandidateBoards[candidateDraftID] {
                refreshed.lastTouchedAt = Date()
                pendingCandidateBoards[candidateDraftID] = refreshed
            }
            startEvolutionGeneration(requestID: requestID,
                                     candidateDraftID: candidateDraftID,
                                     candidate: candidate,
                                     candidateIndex: index,
                                     styleTuningNote: styleTuningNote,
                                     quality: quality)
        case "petRegenerateStage":
            pruneStudioState()
            guard let requestID = generationRequestID(body["requestID"]),
                  let draftID = generationRequestID(body["draftID"]),
                  let evolution = pendingEvolutionSheets[draftID],
                  let index = (body["stageIndex"] as? NSNumber)?.intValue,
                  let stage = PetEvolutionStage.allCases.first(where: { $0.sheetIndex == index }) else {
                settingsCall("petStudioError", [
                    "requestID": body["requestID"] as? String ?? "",
                    "kind": "setup", "phase": "input", "code": "evolution_expired",
                    "messageZh": "这张成长图已过期；米墨没有发出单段重画请求。请从 Low 草稿重新开始。",
                    "messageEn": "This evolution draft expired; Mimo did not submit a redraw. Start again from Low drafts.",
                    "outputRetained": false, "requestNotStarted": true,
                    "resetTo": "candidates",
                ])
                return
            }
            let stageQuality = (body["quality"] as? String).map {
                PetFinalGenerationQuality.resolve($0)
            } ?? evolution.quality
            let styleTuningNote = (body["styleTuningNote"] as? String).map {
                PetVisualTuningNote.sanitize($0)
            } ?? evolution.styleTuningNote
            startStageRegeneration(requestID: requestID, parentDraftID: draftID,
                                   stage: stage, evolution: evolution,
                                   styleTuningNote: styleTuningNote,
                                   quality: stageQuality)
        case "petRetryLocalProcessing":
            pruneStudioState()
            guard let requestID = generationRequestID(body["requestID"]),
                  pendingLocalRecoveries[requestID] != nil else {
                settingsCall("petStudioError", [
                    "requestID": body["requestID"] as? String ?? "",
                    "kind": "setup", "phase": "recovery", "code": "recovery_expired",
                    "messageZh": "这份会话内恢复稿已过期；不会产生新的费用。",
                    "messageEn": "This in-session recovery draft expired; no new cost was incurred.",
                    "outputRetained": false, "requestNotStarted": true,
                ])
                return
            }
            retryLocalGeneration(requestID)
        case "petContinueInBackground":
            if let requestID = generationRequestID(body["requestID"]) {
                backgroundStudioRequests.insert(requestID)
            }
            settingsWin?.close()
        case "petRevealGenerationDrafts":
            NSWorkspace.shared.activateFileViewerSelecting([generationDraftStore.folderURL])
        case "petInstallRaster":
            // Canonicalized like requestID: these index in-memory dictionaries,
            // so an uppercase UUID from the WebView silently read as "draft
            // expired" — exactly the confusion generationRequestID exists to
            // prevent.
            guard let draftID = generationRequestID(body["draftID"]),
                  let evolution = pendingEvolutionSheets[draftID] else {
                if visibleEvolutionDraftID == generationRequestID(body["draftID"]) {
                    visibleEvolutionDraftID = nil
                }
                settingsCall("petInstallError", [
                    "draftID": body["draftID"] as? String ?? "",
                    "code": "preview_expired",
                    "messageZh": "这张预览已过期，请重新生成。",
                    "messageEn": "This preview expired; generate it again.",
                ])
                return
            }
            let requestedName = (body["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = requestedName.isEmpty ? voice("我的小伴灵", "My little familiar") : String(requestedName.prefix(60))
            let profile = CustomPetTemperaments.profile(for: evolution.temperamentID)
            do {
                let spec = try customPetStore.install(pngData: evolution.pngData, name: name,
                                                      temperamentID: profile.id, accent: profile.accent)
                let expressionStagePNGs = evolution.stagePNGs
                pendingEvolutionSheets.removeValue(forKey: draftID)
                visibleEvolutionDraftID = nil
                visibleCandidateDraftID = nil
                for relatedID in evolution.relatedRequestIDs {
                    pendingCandidateBoards.removeValue(forKey: relatedID)
                    pendingLocalRecoveries.removeValue(forKey: relatedID)
                    _ = try? generationDraftStore.delete(requestID: relatedID)
                }
                guard let characterID = spec["characterID"] as? String,
                      JSONSerialization.isValidJSONObject(spec),
                      let data = try? JSONSerialization.data(withJSONObject: spec),
                      let json = String(data: data, encoding: .utf8) else {
                    throw CustomPetStoreError.corruptManifest
                }
                d.set(characterID, forKey: "character")
                _ = try starterActionJobStore.ensureJobs(characterID: characterID)
                js("famSetCustomPet(\(json))")
                refreshNativeCompanion()
                settingsCall("customPetAdopted", ["spec": spec])
                pushSettingsState()
                revealOverlay()
                // Expression sheets ride along after adoption: blink/joy/rest
                // frames. Only the mature form gets them — the runtime always
                // draws that form, so expressions for the other two slices
                // would be paid for and never seen. Optional — a failure
                // leaves a static familiar.
                if body["skipExpressions"] as? Bool != true {
                    startExpressionRun(characterID: characterID,
                                       stagePNGs: expressionStagePNGs,
                                       temperamentID: profile.id,
                                       stages: [2])
                }
            } catch {
                settingsCall("petInstallError", [
                    "draftID": draftID, "code": "install_failed",
                    "messageZh": "无法把这套伴灵保存到本机：\(error.localizedDescription)",
                    "messageEn": "Could not save this familiar on the Mac: \(error.localizedDescription)",
                ])
            }
        case "petRegenerateExpressions":
            guard let characterID = body["characterID"] as? String else { return }
            do {
                let spec = try customPetStore.runtimeSpec(characterID: characterID)
                guard let assetURLString = spec["assetURL"] as? String,
                      let assetURL = URL(string: assetURLString) else {
                    throw CustomPetStoreError.corruptManifest
                }
                let sheetData = try customPetStore.assetData(for: assetURL)
                let stagePNGs = try (0..<3).map {
                    try CharacterSheetProcessor.extractNormalizedStage(
                        fromNormalizedSheet: sheetData, stageIndex: $0)
                }
                // Only the mature form matters — the runtime never draws the
                // other slices. Default fills its gap; an explicit stageIndex
                // still allows a targeted redraw; "redraw" with nothing
                // missing redoes the mature form.
                let existing = Set((spec["expressionURLs"] as? [String: String])?.keys
                    .compactMap { Int($0) } ?? [])
                var stages = existing.contains(2) ? [] : [2]
                if let index = body["stageIndex"] as? Int { stages = [index] }
                else if stages.isEmpty { stages = [2] }
                startExpressionRun(characterID: characterID, stagePNGs: stagePNGs,
                                   temperamentID: spec["temperamentID"] as? String ?? "",
                                   stages: stages)
            } catch {
                settingsCall("petExpressionError", [
                    "characterID": characterID, "stageIndex": body["stageIndex"] as? Int ?? 0,
                    "code": "setup_failed",
                    "messageZh": "无法准备表情生成：\(error.localizedDescription)",
                    "messageEn": "Could not prepare expression generation: \(error.localizedDescription)",
                ])
            }
        case "petDelete":
            guard let characterID = body["characterID"] as? String else { return }
            let runtime = try? customPetStore.runtimeSpec(characterID: characterID)
            let legacy = characterID == "prototype" ? storedCustomPetSpec() : nil
            guard let name = (runtime?["name"] as? String) ?? (legacy?["name"] as? String) else {
                settingsCall("petDeleteFailed", ["message": voice("找不到这个 DIY 角色", "This DIY familiar could not be found")])
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = voice("让「\(name)」离开桌面？", "Remove “\(name)” from Mimo?")
            alert.informativeText = voice(
                "这会删除它的三段形态。成长等级、活动记录和 API Key 会保留。此操作不能撤销。",
                "Its three forms will be deleted. Growth level, activity history, and API keys stay. This can’t be undone."
            )
            alert.addButton(withTitle: voice("删除角色", "Delete familiar"))
            alert.addButton(withTitle: voice("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                if characterID == "prototype" {
                    d.removeObject(forKey: "customPetSpec")
                    js("famUnregisterPrototypePet()")
                } else {
                    try customPetStore.delete(characterID: characterID)
                    js("famUnregisterCustomPet(\(jsonStr(characterID)))")
                }
                if d.string(forKey: "character") == characterID {
                    d.set("lulu", forKey: "character")
                    js("famSetCharacter('lulu')")
                    refreshNativeCompanion()
                }
                pushSettingsState()
            } catch {
                settingsCall("petDeleteFailed", ["message": error.localizedDescription])
            }
        case "petRename":
            guard let characterID = body["characterID"] as? String,
                  let name = body["name"] as? String else { return }
            do {
                let spec = try customPetStore.rename(
                    characterID: characterID, name: name)
                if JSONSerialization.isValidJSONObject(spec),
                   let data = try? JSONSerialization.data(withJSONObject: spec),
                   let json = String(data: data, encoding: .utf8) {
                    js("famSetCustomPet(\(json), false)")
                }
                if d.string(forKey: "character") == characterID {
                    refreshNativeCompanion()
                }
                settingsCall("petRenamed", ["spec": spec])
                pushSettingsState()
            } catch {
                settingsCall("petRenameFailed", [
                    "message": voice(
                        "改名失败：请输入 1–60 个字符。",
                        "Could not rename: use 1–60 characters."),
                ])
            }
        case "grant":
            grantAutomation()
        case "recheck":
            pushSettingsState()
        case "rule":
            if let key = body["key"] as? String, let kind = body["kind"] as? String {
                if kind == defaultKind(key) { ruleOverrides.removeValue(forKey: key) }
                else { ruleOverrides[key] = kind }
                saveOverrides()
                lastSent = ""
                if let front = NSWorkspace.shared.frontmostApplication { send(app: front) }
            }
        case "idle":
            if let secs = body["secs"] as? Double { d.set(secs, forKey: "idleThreshold") }
        case "companionScale":
            if let raw = body["percent"] as? NSNumber {
                let percent = CompanionDisplaySize.clampedPercent(CGFloat(raw.doubleValue))
                d.set(Double(percent), forKey: "companionDisplayScalePercent")
                applyCompanionDisplayScale()
            }
        case "sounds":
            d.set(body["on"] as? Bool ?? false, forKey: "soundOn")
        case "language":
            let lang = body["language"] as? String == "en" ? "en" : "zh"
            d.set(lang, forKey: "voiceLanguage")
            js("famSetLanguage('\(lang)')")
            settingsWin?.title = voice("Mimo 米墨", "Mimo")
            buildMainMenu()
            rebuildStatusItem()
            pushSettingsState()
        case "login":
            let svc = SMAppService.mainApp
            if body["on"] as? Bool == true { try? svc.register() } else { try? svc.unregister() }
        case "projects":
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = GitWatcher.projectsDir()
            if panel.runModal() == .OK, let url = panel.url {
                d.set(url.path, forKey: "projectsDir")
                gitWatcher.resetAndScan()
            }
            pushSettingsState()
        case "retention":
            if let days = body["days"] as? Int {
                d.set(days, forKey: "retentionDays")
                pruneOldLogs()
                pushSettingsState()
            }
        case "forget":
            switch body["span"] as? String ?? "" {
            case "hour":
                let ts = Date().timeIntervalSince1970 * 1000 - 3_600_000
                let erased = eraseSince(ts); js("famEraseSince(\(ts))")
                if !erased { warnEraseIncomplete() }
            case "today":
                let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
                let erased = eraseSince(start); js("famEraseSince(\(start))")
                if !erased { warnEraseIncomplete() }
            case "all":
                let a = NSAlert()
                a.messageText = voice("删除全部历史记录？", "Delete all history?")
                a.informativeText = voice("所有活动记录和未采用的生成草稿都会消失；XP、等级和已采用的伴灵会保留。此操作无法撤销。",
                                         "Every day of activity and every unadopted generation draft, gone. XP, level, and adopted familiars stay. No undo.")
                a.addButton(withTitle: voice("全部删除", "Delete Everything"))
                a.addButton(withTitle: voice("取消", "Cancel"))
                a.alertStyle = .warning
                if a.runModal() == .alertFirstButtonReturn {
                    eraseAllHistory()
                    // Generated drafts are derived from the user's own uploaded
                    // photos and live for up to 24h. A "delete everything"
                    // framed as a privacy eraser must not leave them behind.
                    _ = try? generationDraftStore.purgeExpired(now: .distantFuture)
                    js("famEraseSince(0)")
                }
            default: break
            }
            pushSettingsState()
        case "reveal":
            NSWorkspace.shared.activateFileViewerSelecting([logDir])
        case "done":
            d.set(true, forKey: "onboarded1")
            settingsWin?.close()
        default:
            break
        }
    }

    @objc func grantAutomation() {
        guard let bid = defaultBrowserBundleId() else { return }
        if NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) == nil,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            _ = activeTab(bundleId: bid)
            self?.pushSettingsState()
        }
    }
}

// ── LuLu, drawn tiny for the menu bar ───────────────────────

func luluStatusIcon() -> NSImage {
    let base = [
        "....Y......YB....",
        "...yY.....YYYy...",
        "..YYYY...YYYY..T.",
        ".YyYYYYYYYYYY.TT.",
        ".YYYYYYYYYYYYyTTT",
        "YYYOOOOOOOOYYYYTT",
        "YYOOOOOOOOOOYYYTT",
        ".YOOOOOOOOOOYYTT.",
        ".YBOOCNCOOOBYYT..",
        "YYOOOCCCOOOOYYY..",
        "YYYOOOOOOOOYYYY..",
        "YYYYYYYYYYYYHHH..",
        ".YYYYYYYYYYYHH...",
        ".YFF.YHHY.FF.H...",
        "..FF......FF.....",
    ]
    let eyes: [(Int, Int, Character)] = [(4,6,"K"),(5,6,"K"),(4,7,"K"),(5,7,"K"),(4,6,"W"),
                                         (9,6,"K"),(10,6,"K"),(9,7,"K"),(10,7,"K"),(9,6,"W")]
    let mouth: [(Int, Int, Character)] = [(5,10,"M"),(7,10,"M")]
    func color(_ ch: Character) -> NSColor? {
        let hex: [Character: Int] = ["Y": 0xffd982, "y": 0xfff0c4, "O": 0xffb043, "C": 0xfff1cf,
                                     "N": 0xc96f3f, "F": 0xf7c778, "T": 0xe69b3d, "B": 0xff9d6b,
                                     "K": 0x2b1c12, "W": 0xffffff, "H": 0xf2bc61, "M": 0x8a5a33]
        guard let v = hex[ch] else { return nil }
        return NSColor(red: CGFloat((v >> 16) & 255) / 255,
                       green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    var grid = base.map { Array($0) }
    for (x, y, ch) in eyes + mouth { grid[y][x] = ch }
    let size = NSSize(width: 18, height: 16)
    let img = NSImage(size: size)
    img.lockFocus()
    let cell: CGFloat = 18.0 / 17.0
    let rows = grid.count
    for (y, row) in grid.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = color(ch) else { continue }
            c.setFill()
            // AppKit origin is bottom-left; flip the row index
            NSRect(x: CGFloat(x) * cell,
                   y: CGFloat(rows - 1 - y) * cell + 0.2,
                   width: cell + 0.05, height: cell + 0.05).fill()
        }
    }
    img.unlockFocus()
    return img
}
