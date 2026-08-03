// Mimo Reflection Browser — local, deterministic domain core.
//
// This file deliberately has no AppKit, WebKit, network, Keychain, or model
// dependencies.  It is safe to link into the command-line test executables.

import Foundation

// MARK: - Shared models

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
        let calendar = input
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
        return .init(start: start, end: end)
    }

    /// The journal's Week view is a rolling local seven-day window: today and
    /// the six preceding civil days. Calendar addition keeps DST boundaries
    /// correct (a local day is not always 86,400 seconds).
    static func week(containing date: Date = Date(), calendar input: Calendar = .current) -> Self {
        let calendar = input
        let today = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -6, to: today)
            ?? today.addingTimeInterval(-6 * 86_400)
        let end = calendar.date(byAdding: .day, value: 1, to: today)
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
    /// Kept locally. Use `SensitiveURLScrubber` before constructing model input.
    var fullURL: String?
    var domain: String?
    var category: String
    var canonicalLabel: String?
    var order: Int
    var isRevisit: Bool
    var isContextSwitch: Bool

    init(id: String, startedAtMS: Double, endedAtMS: Double, app: String,
         title: String? = nil, fullURL: String? = nil, domain: String? = nil,
         category: String, canonicalLabel: String? = nil, order: Int,
         isRevisit: Bool = false, isContextSwitch: Bool = false) {
        self.id = id
        self.startedAtMS = startedAtMS
        self.endedAtMS = max(startedAtMS, endedAtMS)
        self.app = app
        self.title = title
        self.fullURL = fullURL
        self.domain = domain
        self.category = category
        self.canonicalLabel = canonicalLabel
        self.order = order
        self.isRevisit = isRevisit
        self.isContextSwitch = isContextSwitch
    }

    var durationMS: Double { max(0, endedAtMS - startedAtMS) }

    var activityKey: String {
        let meaningful = canonicalLabel?.trimmedNonempty
            ?? domain?.trimmedNonempty
            ?? title?.trimmedNonempty
            ?? app
        return "\(category.lowercased())|\(meaningful.lowercased())"
    }

    func modelSafeCopy() -> ActivityEvent {
        var copy = self
        copy.fullURL = fullURL.map(SensitiveURLScrubber.scrub)
        return copy
    }
}

enum ReflectionType: String, Codable, Equatable {
    case daily
    case summary
    case weekly
    case unknown
}

struct NotionReflection: Codable, Equatable {
    var id: String
    var title: String
    var reflectionDate: Date?
    var reflectionType: ReflectionType
    var markdown: String
    var pageID: String
    var pageURL: String
    var lastEditedAt: Date?
    var syncedAt: Date

    init(id: String, title: String, reflectionDate: Date? = nil,
         reflectionType: ReflectionType = .unknown, markdown: String,
         pageID: String, pageURL: String, lastEditedAt: Date? = nil,
         syncedAt: Date) {
        self.id = id
        self.title = title
        self.reflectionDate = reflectionDate
        self.reflectionType = reflectionType
        self.markdown = markdown
        self.pageID = pageID
        self.pageURL = pageURL
        self.lastEditedAt = lastEditedAt
        self.syncedAt = syncedAt
    }
}

enum EvidenceSourceKind: String, Codable, Equatable {
    case activity
    case notion
}

enum EvidenceClaimKind: String, Codable, Equatable {
    case fact
    case quote
    case inference
}

struct ReflectionEvidence: Codable, Equatable {
    var id: String
    var sourceKind: EvidenceSourceKind
    /// ActivityEvent.id or NotionReflection.id.
    var sourceID: String
    var claimKind: EvidenceClaimKind
    var label: String
    var excerpt: String
    var timestampMS: Double?
    var sourceURL: String?

    init(id: String, sourceKind: EvidenceSourceKind, sourceID: String,
         claimKind: EvidenceClaimKind, label: String, excerpt: String,
         timestampMS: Double? = nil, sourceURL: String? = nil) {
        self.id = id
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.claimKind = claimKind
        self.label = label
        self.excerpt = excerpt
        self.timestampMS = timestampMS
        self.sourceURL = sourceURL
    }
}

enum ReflectionMarkKind: String, Codable, Equatable {
    case highlight
    case underline
}

struct ReflectionMark: Codable, Equatable {
    var id: String
    var conversationID: String
    var messageID: String
    var kind: ReflectionMarkKind
    var location: Int
    var length: Int
    /// Stable selected text lets marks survive after the current synthesis is
    /// moved into conversation history. Older persisted marks decode as nil
    /// and continue to resolve from their recorded range.
    var text: String?
    /// Evidence scope captured from the trusted source claim/message when the
    /// mark is created. Older persisted marks decode as nil and are resolved
    /// from their source before they may cross a model/writeback boundary.
    var evidenceIDs: [String]?
    var createdAt: Date

    init(id: String, conversationID: String, messageID: String,
         kind: ReflectionMarkKind, location: Int, length: Int,
         text: String? = nil,
         evidenceIDs: [String]? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.messageID = messageID
        self.kind = kind
        self.location = max(0, location)
        self.length = max(0, length)
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.createdAt = createdAt
    }
}

/// A marked excerpt may only cross an analysis/writeback boundary when every
/// source evidence item remains inside the user's newly confirmed scope.
struct ReflectionMarkedExcerpt: Equatable {
    var text: String
    var evidenceIDs: [String]
}

enum ReflectionMarkScope {
    static func retained(_ candidates: [ReflectionMarkedExcerpt],
                         allowedEvidenceIDs: [String]) -> [ReflectionMarkedExcerpt] {
        let allowed = Set(allowedEvidenceIDs)
        guard !allowed.isEmpty else { return [] }
        var output: [ReflectionMarkedExcerpt] = []
        var indexByText: [String: Int] = [:]
        for candidate in candidates {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var evidenceIDs: [String] = []
            for id in candidate.evidenceIDs where !id.isEmpty && !evidenceIDs.contains(id) {
                evidenceIDs.append(id)
            }
            guard !text.isEmpty, !evidenceIDs.isEmpty,
                  evidenceIDs.allSatisfy(allowed.contains) else { continue }
            if let index = indexByText[text] {
                for id in evidenceIDs where !output[index].evidenceIDs.contains(id) {
                    output[index].evidenceIDs.append(id)
                }
            } else {
                indexByText[text] = output.count
                output.append(.init(text: text, evidenceIDs: evidenceIDs))
            }
        }
        return output
    }
}

enum ReflectionPersistedStateSchema {
    static let currentVersion = 2

    static func requiresDerivedReset(from version: Int) -> Bool {
        version > 0 && version < currentVersion
    }

    static func resetDerivedState(
        marks: inout [ReflectionMark],
        conversation: inout ReflectionConversation,
        synthesis: inout LocalReflectionSynthesis?,
        draft: inout SynthesisDraft?
    ) {
        marks = []
        conversation = ReflectionConversation(
            id: "reflection-main", title: "Mimo Reflection Browser")
        synthesis = nil
        draft = nil
    }
}

/// Converts WebKit's UTF-16 selection coordinates into the character offsets
/// persisted by `ReflectionMark`. A text-only fallback is accepted only when
/// the selected phrase occurs once, so choosing the second copy of a repeated
/// sentence can never silently mark the first.
enum ReflectionTextRangeResolver {
    static func characterOffsets(in source: String, selectedText: String,
                                 utf16Location: Int?, utf16Length: Int?)
        -> (location: Int, length: Int)? {
        guard !selectedText.isEmpty else { return nil }
        if let utf16Location, let utf16Length,
           utf16Location >= 0, utf16Length > 0 {
            let nsSource = source as NSString
            let nsRange = NSRange(location: utf16Location, length: utf16Length)
            guard NSMaxRange(nsRange) <= nsSource.length,
                  nsSource.substring(with: nsRange) == selectedText,
                  let range = Range(nsRange, in: source) else { return nil }
            return (source.distance(from: source.startIndex, to: range.lowerBound),
                    source.distance(from: range.lowerBound, to: range.upperBound))
        }

        var onlyMatch: Range<String.Index>?
        var cursor = source.startIndex
        while cursor < source.endIndex,
              let match = source.range(of: selectedText,
                                       range: cursor..<source.endIndex) {
            guard onlyMatch == nil else { return nil }
            onlyMatch = match
            // Advance one grapheme from the match start, not to its end, so
            // overlapping duplicates also make this legacy path fail closed.
            cursor = source.index(after: match.lowerBound)
        }
        guard let range = onlyMatch else { return nil }
        return (source.distance(from: source.startIndex, to: range.lowerBound),
                source.distance(from: range.lowerBound, to: range.upperBound))
    }

    static func characterRange(in source: String, location: Int,
                               length: Int) -> Range<String.Index>? {
        guard location >= 0, length > 0,
              let start = source.index(source.startIndex, offsetBy: location,
                                       limitedBy: source.endIndex),
              let end = source.index(start, offsetBy: length,
                                     limitedBy: source.endIndex) else { return nil }
        return start..<end
    }

    static func utf16Range(in source: String, location: Int,
                           length: Int) -> NSRange? {
        guard let range = characterRange(in: source, location: location,
                                         length: length) else { return nil }
        return NSRange(range, in: source)
    }
}

enum ReflectionMessageRole: String, Codable, Equatable {
    case user
    case assistant
    case system
}

struct ReflectionMessage: Codable, Equatable {
    var id: String
    var role: ReflectionMessageRole
    var content: String
    var evidenceIDs: [String]
    var createdAt: Date

    init(id: String, role: ReflectionMessageRole, content: String,
         evidenceIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.evidenceIDs = evidenceIDs
        self.createdAt = createdAt
    }
}

struct ReflectionConversation: Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ReflectionMessage]

    init(id: String, title: String, createdAt: Date = Date(),
         updatedAt: Date = Date(), messages: [ReflectionMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

enum WritebackTarget: String, Codable, Equatable {
    case appendPage
    case createPage
}

struct SynthesisDraft: Codable, Equatable {
    var id: String
    var dateRange: ReflectionDateRange
    var title: String
    var markdown: String
    var evidenceIDs: [String]
    var target: WritebackTarget
    var targetPageID: String?
    var createdAt: Date
    var idempotencyKey: String
    /// Nil until the user explicitly confirms writeback.
    var confirmedAt: Date?

    init(id: String, dateRange: ReflectionDateRange, title: String,
         markdown: String, evidenceIDs: [String], target: WritebackTarget,
         targetPageID: String? = nil, createdAt: Date = Date(),
         idempotencyKey: String, confirmedAt: Date? = nil) {
        self.id = id
        self.dateRange = dateRange
        self.title = title
        self.markdown = markdown
        self.evidenceIDs = evidenceIDs
        self.target = target
        self.targetPageID = targetPageID
        self.createdAt = createdAt
        self.idempotencyKey = idempotencyKey
        self.confirmedAt = confirmedAt
    }
}

struct NotionSyncState: Codable, Equatable {
    var sourceID: String
    var sourceURL: String
    var lastSyncedAt: Date?
    var lastEditedAtByPage: [String: Date]
    var cachedPageIDs: [String]
    var nextCursor: String?
    var hasMore: Bool
    var lastError: String?

    init(sourceID: String, sourceURL: String, lastSyncedAt: Date? = nil,
         lastEditedAtByPage: [String: Date] = [:], cachedPageIDs: [String] = [],
         nextCursor: String? = nil, hasMore: Bool = false,
         lastError: String? = nil) {
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.lastSyncedAt = lastSyncedAt
        self.lastEditedAtByPage = lastEditedAtByPage
        self.cachedPageIDs = cachedPageIDs
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.lastError = lastError
    }
}

// MARK: - Activity parsing and aggregation

struct ActivityParseResult: Equatable {
    var events: [ActivityEvent]
    /// One-based non-empty input line numbers that could not be decoded as an event.
    var malformedLineNumbers: [Int]
    /// Files that existed in the requested archive set but could not be read.
    /// Keeping this separate from malformed lines lets the UI distinguish a
    /// partial archive from an empty day.
    var unreadableSourceIDs: [String] = []
}

enum ActivityJSONLParser {
    static func parse(_ text: String, sourceID: String,
                      range: ReflectionDateRange? = nil,
                      startingOrder: Int = 0) -> ActivityParseResult {
        var parsed: [ActivityEvent] = []
        var malformed: [Int] = []
        var fingerprintOccurrences: [String: Int] = [:]

        for (lineOffset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t0 = number(object["t0"]), let t1 = number(object["t1"]),
                  t1 >= t0, let app = string(object["app"]), !app.isEmpty else {
                malformed.append(lineOffset + 1)
                continue
            }

            let url = string(object["url"])?.trimmedNonempty
            let title = (string(object["detail"]) ?? string(object["title"]))?.trimmedNonempty
            let category = string(object["kind"])?.trimmedNonempty ?? "neutral"
            let canonical = string(object["canon"])?.trimmedNonempty
            let parsedHost = url.flatMap { URL(string: $0)?.host?.lowercased() }
            let host = parsedHost?.replacingOccurrences(
                of: "^www\\.", with: "", options: .regularExpression)
            let fingerprint = [String(t0), String(t1), app, title ?? "", url ?? "",
                               category, canonical ?? ""].joined(separator: "\u{1f}")
            let occurrence = fingerprintOccurrences[fingerprint, default: 0]
            fingerprintOccurrences[fingerprint] = occurrence + 1
            let id = stableID(prefix: "activity", value: "\(sourceID)|\(fingerprint)|\(occurrence)")
            let event = ActivityEvent(
                id: id, startedAtMS: t0, endedAtMS: t1, app: app,
                title: title, fullURL: url, domain: host, category: category,
                canonicalLabel: canonical, order: startingOrder + parsed.count)
            if range == nil || range!.intersects(startedAtMS: t0, endedAtMS: t1) {
                parsed.append(event)
            }
        }

        parsed.sort {
            if $0.startedAtMS == $1.startedAtMS { return $0.order < $1.order }
            return $0.startedAtMS < $1.startedAtMS
        }
        var seen = Set<String>()
        var priorKey: String?
        for index in parsed.indices {
            let key = parsed[index].activityKey
            parsed[index].isRevisit = seen.contains(key) && priorKey != key
            parsed[index].isContextSwitch = priorKey != nil && priorKey != key
            seen.insert(key)
            priorKey = key
            parsed[index].order = startingOrder + index
        }
        return ActivityParseResult(events: parsed, malformedLineNumbers: malformed)
    }

    static func read(urls: [URL], range: ReflectionDateRange? = nil) -> ActivityParseResult {
        var all: [ActivityEvent] = []
        var malformed: [Int] = []
        var unreadable: [String] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let result = parse(text, sourceID: url.lastPathComponent,
                               range: range, startingOrder: all.count)
            all.append(contentsOf: result.events)
            malformed.append(contentsOf: result.malformedLineNumbers)
        }
        all.sort {
            if $0.startedAtMS == $1.startedAtMS { return $0.order < $1.order }
            return $0.startedAtMS < $1.startedAtMS
        }
        // Re-derive cross-file sequence metadata.
        var seen = Set<String>()
        var priorKey: String?
        for index in all.indices {
            let key = all[index].activityKey
            all[index].isRevisit = seen.contains(key) && priorKey != key
            all[index].isContextSwitch = priorKey != nil && priorKey != key
            seen.insert(key)
            priorKey = key
            all[index].order = index
        }
        return .init(events: all, malformedLineNumbers: malformed,
                     unreadableSourceIDs: unreadable)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? { value as? String }
}

struct ActivityAggregate: Codable, Equatable {
    var id: String
    var key: String
    var label: String
    var category: String
    var durationMS: Double
    var revisitCount: Int
    var contextSwitchCount: Int
    /// Ordered references only: raw events remain the source of truth.
    var rawEventIDs: [String]

    func expanded(using events: [ActivityEvent]) -> [ActivityEvent] {
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        return rawEventIDs.compactMap { byID[$0] }.sorted { $0.order < $1.order }
    }
}

enum ActivityAggregator {
    static func aggregate(_ events: [ActivityEvent]) -> [ActivityAggregate] {
        let ordered = events.sorted { $0.order < $1.order }
        var aggregateByKey: [String: ActivityAggregate] = [:]
        var keyOrder: [String] = []
        for event in ordered {
            let key = event.activityKey
            if aggregateByKey[key] == nil {
                keyOrder.append(key)
                aggregateByKey[key] = ActivityAggregate(
                    id: stableID(prefix: "aggregate", value: key), key: key,
                    label: event.canonicalLabel?.trimmedNonempty
                        ?? event.domain?.trimmedNonempty
                        ?? event.title?.trimmedNonempty
                        ?? event.app,
                    category: event.category, durationMS: 0, revisitCount: 0,
                    contextSwitchCount: 0, rawEventIDs: [])
            }
            aggregateByKey[key]!.durationMS += event.durationMS
            aggregateByKey[key]!.revisitCount += event.isRevisit ? 1 : 0
            aggregateByKey[key]!.contextSwitchCount += event.isContextSwitch ? 1 : 0
            aggregateByKey[key]!.rawEventIDs.append(event.id)
        }
        return keyOrder.compactMap { aggregateByKey[$0] }
    }

    /// Expands every aggregate and restores the original global event order.
    /// A duplicated ID in malformed aggregate input is emitted only once.
    static func expandLosslessly(_ aggregates: [ActivityAggregate],
                                 events: [ActivityEvent]) -> [ActivityEvent] {
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var seen = Set<String>()
        return aggregates.flatMap(\.rawEventIDs)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0] }
            .sorted { $0.order < $1.order }
    }
}

// MARK: - Evidence and privacy

enum ReflectionSource: Equatable {
    case activity(ActivityEvent)
    case notion(NotionReflection)
}

struct EvidenceResolver {
    private let activities: [String: ActivityEvent]
    private let reflections: [String: NotionReflection]

    init(activities: [ActivityEvent], reflections: [NotionReflection]) {
        self.activities = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        self.reflections = Dictionary(uniqueKeysWithValues: reflections.map { ($0.id, $0) })
    }

    func resolve(_ evidence: ReflectionEvidence) -> ReflectionSource? {
        switch evidence.sourceKind {
        case .activity:
            return activities[evidence.sourceID].map(ReflectionSource.activity)
        case .notion:
            return reflections[evidence.sourceID].map(ReflectionSource.notion)
        }
    }

    func unresolved(_ evidence: [ReflectionEvidence]) -> [ReflectionEvidence] {
        evidence.filter { resolve($0) == nil }
    }
}

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

    static func scrub(_ raw: String) -> String {
        scrub(raw, depth: 0)
    }

    private static func scrub(_ raw: String, depth: Int) -> String {
        guard var components = URLComponents(string: raw) else {
            // A partially parsed authority can retain userinfo or an opaque
            // query. Do not return any part of an unparseable model-bound URL.
            return redactedURL
        }
        // Credentials are never useful reflection context.
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

    /// QueryItems decodes one layer. Redirectors regularly add another one;
    /// inspect a small bounded number and drop values that remain opaque.
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

    /// Scrub every HTTP(S) URL embedded in otherwise free-form model-bound
    /// text (Markdown, excerpts, prompts, and prior dialogue). Structured URL
    /// fields alone are not enough: Notion Markdown commonly contains signed
    /// media links with credentials in their query strings.
    static func scrubURLs(in text: String) -> String {
        scrubURLs(in: text, depth: 0)
    }

    private static func scrubURLs(in text: String, depth: Int) -> String {
        guard !text.isEmpty else { return text }
        let pattern = #"https?://[^\s<>\"']+"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return text }
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

// MARK: - Deterministic offline synthesis

enum ReflectionSectionKind: String, Codable, Equatable, CaseIterable {
    case chronology = "Chronology"
    case themes = "Themes"
    case reflectionVsReality = "Reflection vs Reality"
    case unresolvedThreads = "Unresolved Threads"
    case questionsWorthCarrying = "Questions Worth Carrying"
    case evidence = "Evidence"
}

struct SynthesisStatement: Codable, Equatable {
    var text: String
    var claimKind: EvidenceClaimKind
    var evidenceIDs: [String]
}

struct ReflectionSynthesisSection: Codable, Equatable {
    var kind: ReflectionSectionKind
    var statements: [SynthesisStatement]
}

struct LocalReflectionSynthesis: Codable, Equatable {
    var sections: [ReflectionSynthesisSection]
    var evidence: [ReflectionEvidence]
}

enum LocalReflectionSynthesizer {
    static func build(events: [ActivityEvent], reflections: [NotionReflection]) -> LocalReflectionSynthesis {
        let events = events.sorted { $0.order < $1.order }
        var evidence: [ReflectionEvidence] = []
        var eventEvidence: [String: String] = [:]
        var notionEvidence: [String: String] = [:]

        for event in events {
            let id = stableID(prefix: "evidence", value: "activity|\(event.id)|fact")
            eventEvidence[event.id] = id
            let subject = event.canonicalLabel?.trimmedNonempty ?? event.title?.trimmedNonempty ?? event.app
            evidence.append(.init(
                id: id, sourceKind: .activity, sourceID: event.id, claimKind: .fact,
                label: subject, excerpt: "\(event.app) · \(subject)",
                timestampMS: event.startedAtMS,
                sourceURL: event.fullURL.map(SensitiveURLScrubber.scrub)))
        }
        for reflection in reflections.sorted(by: reflectionSort) {
            let id = stableID(prefix: "evidence", value: "notion|\(reflection.id)|quote")
            notionEvidence[reflection.id] = id
            evidence.append(.init(
                id: id, sourceKind: .notion, sourceID: reflection.id, claimKind: .quote,
                label: reflection.title,
                excerpt: firstMeaningfulLine(reflection.markdown) ?? reflection.title,
                sourceURL: reflection.pageURL))
        }

        let chronology = events.map { event in
            let minutes = Int((event.durationMS / 60_000).rounded())
            let subject = event.canonicalLabel?.trimmedNonempty ?? event.title?.trimmedNonempty ?? event.app
            return SynthesisStatement(text: "\(subject) · \(minutes) min", claimKind: .fact,
                                      evidenceIDs: eventEvidence[event.id].map { [$0] } ?? [])
        }

        let grouped = Dictionary(grouping: events, by: { $0.category })
        let themes = grouped.keys.sorted().compactMap { category -> SynthesisStatement? in
            guard let group = grouped[category], !group.isEmpty else { return nil }
            let ids = group.compactMap { eventEvidence[$0.id] }
            let minutes = Int((group.reduce(0) { $0 + $1.durationMS } / 60_000).rounded())
            return .init(text: "\(category): \(minutes) min across \(group.count) event(s)",
                         claimKind: .inference, evidenceIDs: ids)
        }

        var comparison: [SynthesisStatement] = []
        for reflection in reflections.sorted(by: reflectionSort) {
            if let evidenceID = notionEvidence[reflection.id] {
                comparison.append(.init(
                    text: "Reflection: \(firstMeaningfulLine(reflection.markdown) ?? reflection.title)",
                    claimKind: .quote, evidenceIDs: [evidenceID]))
            }
        }
        if !events.isEmpty, !reflections.isEmpty {
            let activityIDs = events.prefix(5).compactMap { eventEvidence[$0.id] }
            let reflectionIDs = reflections.prefix(3).compactMap { notionEvidence[$0.id] }
            comparison.append(.init(
                text: "Compare the written emphasis with the largest observed activity blocks.",
                claimKind: .inference, evidenceIDs: reflectionIDs + activityIDs))
        }

        let revisits = Dictionary(grouping: events.filter(\.isRevisit), by: { $0.activityKey })
        let unresolved = revisits.keys.sorted().compactMap { key -> SynthesisStatement? in
            guard let group = revisits[key], let first = group.first else { return nil }
            let label = first.canonicalLabel?.trimmedNonempty ?? first.title?.trimmedNonempty ?? first.app
            return .init(text: "\(label) was returned to \(group.count) time(s).",
                         claimKind: .inference,
                         evidenceIDs: group.compactMap { eventEvidence[$0.id] })
        }

        var questions: [SynthesisStatement] = []
        if let longest = events.max(by: { $0.durationMS < $1.durationMS }),
           let id = eventEvidence[longest.id] {
            let label = longest.canonicalLabel?.trimmedNonempty ?? longest.title?.trimmedNonempty ?? longest.app
            questions.append(.init(text: "What made \(label) worth the largest block of attention?",
                                   claimKind: .inference, evidenceIDs: [id]))
        }
        if let reflection = reflections.sorted(by: reflectionSort).first,
           let id = notionEvidence[reflection.id] {
            questions.append(.init(text: "What from \(reflection.title) should be carried into the next day?",
                                   claimKind: .inference, evidenceIDs: [id]))
        }

        let evidenceStatements = evidence.map {
            SynthesisStatement(text: "[\($0.claimKind.rawValue)] \($0.label): \($0.excerpt)",
                               claimKind: $0.claimKind, evidenceIDs: [$0.id])
        }
        let byKind: [ReflectionSectionKind: [SynthesisStatement]] = [
            .chronology: chronology,
            .themes: themes,
            .reflectionVsReality: comparison,
            .unresolvedThreads: unresolved,
            .questionsWorthCarrying: questions,
            .evidence: evidenceStatements,
        ]
        let sections = ReflectionSectionKind.allCases.map {
            ReflectionSynthesisSection(kind: $0, statements: byKind[$0] ?? [])
        }
        return .init(sections: sections, evidence: evidence)
    }

    private static func reflectionSort(_ lhs: NotionReflection, _ rhs: NotionReflection) -> Bool {
        (lhs.reflectionDate ?? lhs.syncedAt) < (rhs.reflectionDate ?? rhs.syncedAt)
    }

    private static func firstMeaningfulLine(_ markdown: String) -> String? {
        markdown.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

// MARK: - Stable local IDs

private func stableID(prefix: String, value: String) -> String {
    // FNV-1a 64-bit is deterministic across processes, unlike Swift's Hasher.
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
