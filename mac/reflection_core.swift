// Mimo Today Journal — local, deterministic activity domain core.
//
// This file deliberately has no AppKit, WebKit, network, Keychain, or model
// dependencies. Raw events remain the source of truth; every derived activity
// block, material, and reflection statement carries raw event IDs.

import Foundation

// MARK: - Date range and raw activity

struct ReflectionDateRange: Codable, Equatable {
    var start: Date
    /// Exclusive upper bound.
    var end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = max(start, end)
    }

    func intersects(startedAtMS: Double, endedAtMS: Double) -> Bool {
        endedAtMS > start.timeIntervalSince1970 * 1_000
            && startedAtMS < end.timeIntervalSince1970 * 1_000
    }

    static func today(containing date: Date = Date(), calendar input: Calendar = .current) -> Self {
        let start = input.startOfDay(for: date)
        let end = input.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return .init(start: start, end: end)
    }

    static func week(containing date: Date = Date(), calendar input: Calendar = .current) -> Self {
        let today = input.startOfDay(for: date)
        let start = input.date(byAdding: .day, value: -6, to: today)
            ?? today.addingTimeInterval(-6 * 86_400)
        let end = input.date(byAdding: .day, value: 1, to: today)
            ?? today.addingTimeInterval(86_400)
        return .init(start: start, end: end)
    }
}

struct ActivityEvent: Codable, Equatable {
    var id: String
    var startedAtMS: Double
    var endedAtMS: Double
    var app: String
    var title: String?
    /// Kept locally. Use `SensitiveURLScrubber` before model projection.
    var fullURL: String?
    var domain: String?
    var bundleIdentifier: String?
    var category: String
    var canonicalLabel: String?
    var order: Int
    var isRevisit: Bool
    var isContextSwitch: Bool

    init(id: String, startedAtMS: Double, endedAtMS: Double, app: String,
         title: String? = nil, fullURL: String? = nil, domain: String? = nil,
         bundleIdentifier: String? = nil, category: String,
         canonicalLabel: String? = nil, order: Int,
         isRevisit: Bool = false, isContextSwitch: Bool = false) {
        self.id = id
        self.startedAtMS = startedAtMS
        self.endedAtMS = max(startedAtMS, endedAtMS)
        self.app = app
        self.title = title
        self.fullURL = fullURL
        self.domain = domain
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.canonicalLabel = canonicalLabel
        self.order = order
        self.isRevisit = isRevisit
        self.isContextSwitch = isContextSwitch
    }

    var durationMS: Double { max(0, endedAtMS - startedAtMS) }

    var activityKey: String {
        let meaningful = canonicalLabel?.trimmedNonempty
            ?? cleanedActivityTitle(title)
            ?? domain?.trimmedNonempty
            ?? app
        return "\(ActivityCategory.classify(self).rawValue)|\(meaningful.lowercased())"
    }

    var displayTitle: String {
        canonicalLabel?.trimmedNonempty
            ?? cleanedActivityTitle(title)
            ?? domain?.trimmedNonempty
            ?? app
    }

    func modelSafeCopy() -> ActivityEvent {
        var copy = self
        copy.fullURL = fullURL.map(SensitiveURLScrubber.scrub)
        return copy
    }
}

struct ActivityParseResult: Equatable {
    var events: [ActivityEvent]
    var malformedLineNumbers: [Int]
    var unreadableSourceIDs: [String] = []
}

enum ActivityJSONLParser {
    static func parse(_ text: String, sourceID: String,
                      range: ReflectionDateRange? = nil,
                      startingOrder: Int = 0) -> ActivityParseResult {
        var parsed: [ActivityEvent] = []
        var malformed: [Int] = []
        var occurrences: [String: Int] = [:]

        for (offset, rawLine) in text.split(
            separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t0 = number(object["t0"]), let t1 = number(object["t1"]),
                  t1 >= t0, let app = string(object["app"]), !app.isEmpty else {
                malformed.append(offset + 1)
                continue
            }

            let url = string(object["url"])?.trimmedNonempty
            let title = (string(object["detail"]) ?? string(object["title"]))?.trimmedNonempty
            let category = string(object["kind"])?.trimmedNonempty ?? "neutral"
            let canonical = string(object["canon"])?.trimmedNonempty
            let bundleIdentifier = (string(object["bundleID"])
                ?? string(object["bundleIdentifier"]))?.trimmedNonempty
            let host = url.flatMap { URL(string: $0)?.host?.lowercased() }?
                .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
            var fingerprintParts = [String(t0), String(t1), app, title ?? "", url ?? "",
                                    category, canonical ?? ""]
            if let bundleIdentifier { fingerprintParts.append(bundleIdentifier) }
            let fingerprint = fingerprintParts.joined(separator: "\u{1f}")
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            let event = ActivityEvent(
                id: stableID(prefix: "activity", value: "\(sourceID)|\(fingerprint)|\(occurrence)"),
                startedAtMS: t0, endedAtMS: t1, app: app, title: title,
                fullURL: url, domain: host, bundleIdentifier: bundleIdentifier,
                category: category,
                canonicalLabel: canonical, order: startingOrder + parsed.count)
            if range == nil || range!.intersects(startedAtMS: t0, endedAtMS: t1) {
                parsed.append(event)
            }
        }
        sequence(&parsed, startingOrder: startingOrder)
        return .init(events: parsed, malformedLineNumbers: malformed)
    }

    static func read(urls: [URL], range: ReflectionDateRange? = nil) -> ActivityParseResult {
        var events: [ActivityEvent] = []
        var malformed: [Int] = []
        var unreadable: [String] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let result = parse(text, sourceID: url.lastPathComponent,
                               range: range, startingOrder: events.count)
            events.append(contentsOf: result.events)
            malformed.append(contentsOf: result.malformedLineNumbers)
        }
        sequence(&events, startingOrder: 0)
        return .init(events: events, malformedLineNumbers: malformed,
                     unreadableSourceIDs: unreadable)
    }

    private static func sequence(_ events: inout [ActivityEvent], startingOrder: Int) {
        events.sort {
            $0.startedAtMS == $1.startedAtMS ? $0.order < $1.order : $0.startedAtMS < $1.startedAtMS
        }
        var seen = Set<String>()
        var priorKey: String?
        for index in events.indices {
            let key = events[index].activityKey
            events[index].isRevisit = seen.contains(key) && priorKey != key
            events[index].isContextSwitch = priorKey != nil && priorKey != key
            events[index].order = startingOrder + index
            seen.insert(key)
            priorKey = key
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? { value as? String }
}

// MARK: - Meaningful activity blocks

enum ActivityCategory: String, Codable, Equatable, CaseIterable {
    case building
    case learning
    case communication
    case planning
    case admin
    case entertainment

    static func classify(_ event: ActivityEvent) -> ActivityCategory {
        let raw = event.category.lowercased()
        let app = event.app.lowercased()
        let domain = event.domain?.lowercased() ?? ""

        if raw == "distraction" { return .entertainment }
        if ["paper", "research", "reading", "learn"].contains(raw) { return .learning }
        if ["code", "term", "cad", "build", "design"].contains(raw) { return .building }
        if ["notes", "planning", "plan"].contains(raw) { return .planning }

        let buildingApps = ["cursor", "xcode", "visual studio code", "vscode", "terminal",
                            "warp", "ghostty", "figma", "claude", "chatgpt"]
        if buildingApps.contains(where: app.contains) { return .building }
        let communicationApps = ["wechat", "mail", "messages", "slack", "teams", "zoom",
                                 "discord", "telegram", "whatsapp", "lark", "feishu"]
        if communicationApps.contains(where: app.contains) { return .communication }
        let planningApps = ["calendar", "reminders", "things", "linear", "asana", "notes",
                            "notion", "obsidian"]
        if planningApps.contains(where: app.contains) { return .planning }
        let entertainmentDomains = ["youtube.com", "bilibili.com", "netflix.com", "reddit.com",
                                    "x.com", "twitter.com", "douyin.com", "weibo.com"]
        if entertainmentDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            return .entertainment
        }
        return .admin
    }
}

struct ActivityBlock: Codable, Equatable {
    var id: String
    var title: String
    var category: ActivityCategory
    var startedAtMS: Double
    var endedAtMS: Double
    var activeDurationMS: Double
    var apps: [String]
    var domains: [String]
    var eventIDs: [String]
    var revisitCount: Int
    var contextSwitchCount: Int

    var elapsedDurationMS: Double { max(0, endedAtMS - startedAtMS) }
}

enum ActivityBlockBuilder {
    /// Events become human-sized blocks. A quick tool switch inside one broad
    /// category stays in the same block; a longer gap or a category change
    /// starts a new block. Identical subjects may reconnect across a longer gap.
    static func build(_ events: [ActivityEvent], quickGapMS: Double = 5 * 60_000,
                      sameSubjectGapMS: Double = 15 * 60_000) -> [ActivityBlock] {
        let ordered = events.sorted { $0.order < $1.order }
        guard !ordered.isEmpty else { return [] }
        var groups: [[ActivityEvent]] = []
        for event in ordered {
            guard var last = groups.popLast() else {
                groups.append([event])
                continue
            }
            let prior = last.last!
            let gap = max(0, event.startedAtMS - prior.endedAtMS)
            let sameSubject = event.activityKey == prior.activityKey
            let sameCategory = ActivityCategory.classify(event) == ActivityCategory.classify(prior)
            if (sameSubject && gap <= sameSubjectGapMS) || (sameCategory && gap <= quickGapMS) {
                last.append(event)
                groups.append(last)
            } else {
                groups.append(last)
                groups.append([event])
            }
        }
        return groups.map(makeBlock)
    }

    private static func makeBlock(_ events: [ActivityEvent]) -> ActivityBlock {
        var titleDurations: [String: Double] = [:]
        for event in events { titleDurations[event.displayTitle, default: 0] += event.durationMS }
        let title = titleDurations.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key ?? events[0].app
        let eventIDs = events.map(\.id)
        return .init(
            id: stableID(prefix: "block", value: eventIDs.joined(separator: "|")),
            title: title,
            category: ActivityCategory.classify(events[0]),
            startedAtMS: events.map(\.startedAtMS).min() ?? 0,
            endedAtMS: events.map(\.endedAtMS).max() ?? 0,
            activeDurationMS: events.reduce(0) { $0 + $1.durationMS },
            apps: unique(events.map(\.app)),
            domains: unique(events.compactMap(\.domain)),
            eventIDs: eventIDs,
            revisitCount: events.filter(\.isRevisit).count,
            contextSwitchCount: events.filter(\.isContextSwitch).count)
    }
}

struct ActivityCategorySummary: Codable, Equatable {
    var category: ActivityCategory
    var durationMS: Double
    var blockCount: Int
    var share: Double
}

enum LearningMaterialKind: String, Codable, Equatable {
    case paper
    case website
    case video
    case document
}

struct LearningMaterial: Codable, Equatable {
    var id: String
    var title: String
    var kind: LearningMaterialKind
    var domain: String?
    var url: String?
    var durationMS: Double
    var encounterCount: Int
    var eventIDs: [String]
    /// Honest local fallback: engagement metadata, never invented contents.
    var localSummary: String
}

enum LearningMaterialExtractor {
    static func extract(_ events: [ActivityEvent]) -> [LearningMaterial] {
        let candidates = events.filter(isLearningMaterial)
        let grouped = Dictionary(grouping: candidates, by: materialKey)
        return grouped.values.map { group in
            let ordered = group.sorted { $0.order < $1.order }
            let first = ordered[0]
            let duration = ordered.reduce(0) { $0 + $1.durationMS }
            let kind = materialKind(first)
            let domain = first.domain
            let minutes = max(1, Int((duration / 60_000).rounded()))
            let source = domain ?? first.app
            let label = kind.rawValue.capitalized
            return LearningMaterial(
                id: stableID(prefix: "material", value: materialKey(first)),
                title: first.displayTitle, kind: kind, domain: domain,
                url: ordered.compactMap(\.fullURL).first,
                durationMS: duration, encounterCount: ordered.count,
                eventIDs: ordered.map(\.id),
                localSummary: "\(label) from \(source) · \(minutes) min across \(ordered.count) visit(s).")
        }.sorted {
            $0.durationMS == $1.durationMS ? $0.title < $1.title : $0.durationMS > $1.durationMS
        }
    }

    private static func isLearningMaterial(_ event: ActivityEvent) -> Bool {
        if ActivityCategory.classify(event) == .learning { return true }
        let domain = event.domain ?? ""
        let learningDomains = ["arxiv.org", "openreview.net", "acm.org", "ieee.org",
                               "medium.com", "substack.com", "wikipedia.org"]
        return learningDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
            || event.fullURL?.lowercased().contains(".pdf") == true
    }

    private static func materialKey(_ event: ActivityEvent) -> String {
        let urlKey = event.fullURL.flatMap { raw -> String? in
            guard var components = URLComponents(string: raw) else { return nil }
            components.query = nil
            components.fragment = nil
            return components.string
        }
        return (urlKey ?? "\(event.domain ?? event.app)|\(event.displayTitle)").lowercased()
    }

    private static func materialKind(_ event: ActivityEvent) -> LearningMaterialKind {
        let url = event.fullURL?.lowercased() ?? ""
        let domain = event.domain?.lowercased() ?? ""
        if domain.contains("youtube.com") || domain.contains("bilibili.com") { return .video }
        if domain.contains("arxiv.org") || domain.contains("openreview.net")
            || url.contains(".pdf") { return .paper }
        if event.app.lowercased().contains("preview") || url.hasSuffix(".epub") { return .document }
        return .website
    }
}

struct DailyActivitySnapshot: Codable, Equatable {
    var range: ReflectionDateRange
    var events: [ActivityEvent]
    var blocks: [ActivityBlock]
    var categories: [ActivityCategorySummary]
    var materials: [LearningMaterial]
    var activeDurationMS: Double
    var focusDurationMS: Double
    var contextSwitchCount: Int

    static func build(range: ReflectionDateRange, events: [ActivityEvent]) -> Self {
        let blocks = ActivityBlockBuilder.build(events)
        let active = events.reduce(0) { $0 + $1.durationMS }
        let grouped = Dictionary(grouping: blocks, by: \.category)
        let categories = ActivityCategory.allCases.compactMap { category -> ActivityCategorySummary? in
            guard let values = grouped[category], !values.isEmpty else { return nil }
            let duration = values.reduce(0) { $0 + $1.activeDurationMS }
            return .init(category: category, durationMS: duration,
                         blockCount: values.count, share: active > 0 ? duration / active : 0)
        }.sorted { $0.durationMS > $1.durationMS }
        let focus = blocks.filter { [.building, .learning, .planning].contains($0.category) }
            .reduce(0) { $0 + $1.activeDurationMS }
        return .init(range: range, events: events, blocks: blocks,
                     categories: categories, materials: LearningMaterialExtractor.extract(events),
                     activeDurationMS: active, focusDurationMS: focus,
                     contextSwitchCount: events.filter(\.isContextSwitch).count)
    }
}

// MARK: - Grounded daily reflection

enum DailyReflectionSectionKind: String, Codable, Equatable, CaseIterable {
    case whatIDid = "What I Did"
    case timeAndAttention = "Time & Attention"
    case learning = "What I Learned"
    case openLoops = "Open Loops"
    case tomorrow = "Carry Forward"
}

enum ReflectionClaimKind: String, Codable, Equatable {
    case fact
    case inference
}

struct GroundedReflectionStatement: Codable, Equatable {
    var text: String
    var claimKind: ReflectionClaimKind
    var evidenceIDs: [String]
}

struct DailyReflectionSection: Codable, Equatable {
    var kind: DailyReflectionSectionKind
    var statements: [GroundedReflectionStatement]
}

struct LearningMaterialSummary: Codable, Equatable {
    var materialID: String
    var overview: String
    var keyIdeas: [String]
    var relevance: String?
    var evidenceIDs: [String]
    var isAIEnhanced: Bool
}

struct DailyReflection: Codable, Equatable {
    var headline: String
    var summary: String
    var sections: [DailyReflectionSection]
    var materialSummaries: [LearningMaterialSummary]
    var isAIEnhanced: Bool
}

enum LocalActivityReflector {
    static func build(snapshot: DailyActivitySnapshot) -> DailyReflection {
        guard !snapshot.events.isEmpty else {
            return .init(headline: "No activity yet",
                         summary: "Mimo will turn local activity into a readable trail as the day unfolds.",
                         sections: DailyReflectionSectionKind.allCases.map {
                             .init(kind: $0, statements: [])
                         }, materialSummaries: [], isAIEnhanced: false)
        }
        let totalMinutes = max(1, Int((snapshot.activeDurationMS / 60_000).rounded()))
        let top = snapshot.categories.first
        let headline = top.map { "A \(humanCategory($0.category))-led day" } ?? "Your day in motion"
        let summary = "\(snapshot.blocks.count) meaningful block(s), \(totalMinutes) active min, "
            + "and \(snapshot.materials.count) learning material(s) captured locally."

        let whatIDid = snapshot.blocks.sorted { $0.activeDurationMS > $1.activeDurationMS }
            .prefix(5).map { block in
                GroundedReflectionStatement(
                    text: "\(block.title) · \(minutes(block.activeDurationMS)) min · \(humanCategory(block.category))",
                    claimKind: .fact, evidenceIDs: block.eventIDs)
            }
        let time = snapshot.categories.map { category in
            GroundedReflectionStatement(
                text: "\(humanCategory(category.category)): \(minutes(category.durationMS)) min "
                    + "(\(Int((category.share * 100).rounded()))%)",
                claimKind: .fact,
                evidenceIDs: snapshot.blocks.filter { $0.category == category.category }
                    .flatMap(\.eventIDs))
        }
        let learning = snapshot.materials.prefix(5).map { material in
            GroundedReflectionStatement(
                text: "\(material.title) · \(minutes(material.durationMS)) min",
                claimKind: .fact, evidenceIDs: material.eventIDs)
        }
        let returned = snapshot.blocks.filter { $0.revisitCount > 0 }
            .sorted { $0.revisitCount > $1.revisitCount }.prefix(4).map { block in
                GroundedReflectionStatement(
                    text: "\(block.title) was revisited \(block.revisitCount) time(s); it may still be open.",
                    claimKind: .inference, evidenceIDs: block.eventIDs)
            }
        let carry: [GroundedReflectionStatement]
        if let longest = snapshot.blocks.max(by: { $0.activeDurationMS < $1.activeDurationMS }) {
            carry = [.init(
                text: "Decide whether \(longest.title) should continue or be closed next.",
                claimKind: .inference, evidenceIDs: longest.eventIDs)]
        } else { carry = [] }

        let byKind: [DailyReflectionSectionKind: [GroundedReflectionStatement]] = [
            .whatIDid: Array(whatIDid), .timeAndAttention: time,
            .learning: Array(learning), .openLoops: Array(returned), .tomorrow: carry,
        ]
        let materialSummaries = snapshot.materials.map { material in
            LearningMaterialSummary(
                materialID: material.id, overview: material.localSummary,
                keyIdeas: [], relevance: nil, evidenceIDs: material.eventIDs,
                isAIEnhanced: false)
        }
        return .init(headline: headline, summary: summary,
                     sections: DailyReflectionSectionKind.allCases.map {
                         .init(kind: $0, statements: byKind[$0] ?? [])
                     }, materialSummaries: materialSummaries, isAIEnhanced: false)
    }
}

// MARK: - Privacy

enum SensitiveURLScrubber {
    private static let sensitiveNames = [
        "token", "key", "code", "password", "passwd", "secret", "auth",
        "session", "credential", "signature", "jwt", "bearer", "oauth"
    ]
    private static let redactedURL = "[redacted-url]"
    private static let maximumNestedDepth = 4
    private static let credentialAssignment = try! NSRegularExpression(
        pattern: #"(?:^|[^a-z0-9])(?:[a-z0-9._-]*(?:token|key|code|password|passwd|secret|auth|session|credential|signature|jwt|bearer|oauth)[a-z0-9._-]*)\s*(?:=|:)"#,
        options: [.caseInsensitive])
    private static let bearerCredential = try! NSRegularExpression(
        pattern: #"(?:^|[^a-z0-9])bearer\s+\S+"#, options: [.caseInsensitive])

    static func scrub(_ raw: String) -> String { scrub(raw, depth: 0) }

    private static func scrub(_ raw: String, depth: Int) -> String {
        guard var components = URLComponents(string: raw) else { return redactedURL }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems {
            components.queryItems = items.compactMap { item in
                guard !isSensitiveName(item.name) else { return nil }
                guard let value = item.value else { return item }
                guard let safeValue = scrubQueryValue(value, depth: depth) else { return nil }
                return URLQueryItem(name: item.name, value: safeValue)
            }
            if components.queryItems?.isEmpty == true { components.queryItems = nil }
        }
        return components.string ?? redactedURL
    }

    private static func isSensitiveName(_ raw: String) -> Bool {
        let normalized = raw.lowercased().replacingOccurrences(
            of: "[^a-z0-9]", with: "", options: .regularExpression)
        return sensitiveNames.contains { normalized.contains($0) }
    }

    private static func scrubQueryValue(_ raw: String, depth: Int) -> String? {
        guard let inspected = fullyDecoded(raw) else { return nil }
        let lowercased = inspected.lowercased()
        if lowercased.contains("http://") || lowercased.contains("https://") {
            guard depth < maximumNestedDepth else { return nil }
            let cleaned = scrubURLs(in: inspected, depth: depth + 1)
            guard let verified = fullyDecoded(cleaned),
                  !containsCredentialPattern(verified) else { return nil }
            return cleaned
        }
        return containsCredentialPattern(inspected) ? nil : raw
    }

    private static func fullyDecoded(_ raw: String) -> String? {
        var value = raw
        for _ in 0..<4 {
            guard value.contains("%") else { return value }
            guard let decoded = value.removingPercentEncoding else { return nil }
            if decoded == value { return value }
            value = decoded
        }
        return value.range(of: #"%[0-9a-fA-F]{2}"#, options: .regularExpression) == nil
            ? value : nil
    }

    private static func containsCredentialPattern(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return credentialAssignment.firstMatch(in: value, range: range) != nil
            || bearerCredential.firstMatch(in: value, range: range) != nil
    }

    static func scrubURLs(in text: String) -> String { scrubURLs(in: text, depth: 0) }

    private static func scrubURLs(in text: String, depth: Int) -> String {
        guard !text.isEmpty,
              let expression = try? NSRegularExpression(
                pattern: #"https?://[^\s<>\"']+"#, options: [.caseInsensitive]) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var output = text
        for match in expression.matches(in: text, range: fullRange).reversed() {
            guard let range = Range(match.range, in: text),
                  let outputRange = Range(match.range, in: output) else { continue }
            var candidate = String(text[range])
            var suffix = ""
            while let last = candidate.last, ".,;:!?)]}".contains(last) {
                suffix.insert(last, at: suffix.startIndex)
                candidate.removeLast()
            }
            output.replaceSubrange(outputRange, with: scrub(candidate, depth: depth) + suffix)
        }
        return output
    }
}

// MARK: - Helpers

private func humanCategory(_ category: ActivityCategory) -> String {
    switch category {
    case .building: return "building"
    case .learning: return "learning"
    case .communication: return "communication"
    case .planning: return "planning"
    case .admin: return "admin"
    case .entertainment: return "entertainment"
    }
}

private func minutes(_ durationMS: Double) -> Int {
    max(1, Int((durationMS / 60_000).rounded()))
}

private func unique(_ values: [String]) -> [String] {
    values.reduce(into: []) { output, value in
        if !value.isEmpty && !output.contains(value) { output.append(value) }
    }
}

private func cleanedActivityTitle(_ raw: String?) -> String? {
    guard var value = raw?.trimmedNonempty else { return nil }
    value = value.replacingOccurrences(
        of: #"\s*[-–—|·]\s*(Google Chrome|Safari|Arc|Brave|YouTube|GitHub|Notion)$"#,
        with: "", options: [.regularExpression, .caseInsensitive])
    value = value.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "",
                                       options: .regularExpression)
    return value.trimmedNonempty
}

private func stableID(prefix: String, value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return "\(prefix)-\(String(hash, radix: 16))"
}

private extension String {
    var trimmedNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
