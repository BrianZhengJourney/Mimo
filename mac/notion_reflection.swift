// Mimo Reflection Browser — Notion import, cache, and explicit writeback.
// The integration token exists only behind NotionTokenStore. It is never
// encoded into cache models, UserDefaults, request errors, or diagnostics.

import Foundation
import Security

let mimoNotionAPIVersion = "2026-03-11"

private func parseNotionISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

// MARK: - Targets and URL parsing

enum NotionTargetKind: String, Codable {
    case page
    case database
    case dataSource
}

struct NotionTarget: Codable, Equatable {
    let kind: NotionTargetKind
    let id: String
}

enum NotionTargetParser {
    private static let compactID = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{32}$")
    private static let uuidID = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    static func normalizeID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let compact: String
        if compactID.firstMatch(in: value, range: range) != nil {
            compact = value.lowercased()
        } else if uuidID.firstMatch(in: value, range: range) != nil {
            compact = value.replacingOccurrences(of: "-", with: "").lowercased()
        } else {
            return nil
        }
        let groups = [8, 4, 4, 4, 12]
        var offset = compact.startIndex
        return groups.map { length in
            let end = compact.index(offset, offsetBy: length)
            defer { offset = end }
            return String(compact[offset..<end])
        }.joined(separator: "-")
    }

    /// Bare IDs deliberately require a hint. A Notion UUID contains no type
    /// information, so silently guessing page vs data source would be unsafe.
    static func parse(_ raw: String, hint: NotionTargetKind? = nil) throws -> NotionTarget {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, kind) in [("page:", NotionTargetKind.page),
                               ("database:", .database),
                               ("data_source:", .dataSource),
                               ("data-source:", .dataSource)] {
            if value.lowercased().hasPrefix(prefix) {
                guard let id = normalizeID(String(value.dropFirst(prefix.count))) else {
                    throw NotionBackendError.invalidTarget
                }
                return NotionTarget(kind: kind, id: id)
            }
        }
        if let id = normalizeID(value) {
            guard let hint else { throw NotionBackendError.invalidTarget }
            return NotionTarget(kind: hint, id: id)
        }
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(), isNotionHost(host) else {
            throw NotionBackendError.invalidTarget
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw NotionBackendError.invalidTarget }

        if let marker = parts.lastIndex(where: { $0 == "data_sources" || $0 == "data-sources" }),
           marker + 1 < parts.count, let id = normalizeID(parts[marker + 1]) {
            return NotionTarget(kind: .dataSource, id: id)
        }

        // Public page URLs commonly end in `title-<32 hex>`. Only a terminal
        // ID is accepted, avoiding accidental extraction from query strings.
        let terminal = parts.last!
        let candidates = [terminal, String(terminal.suffix(36)), String(terminal.suffix(32))]
        guard let id = candidates.compactMap(normalizeID).first else {
            throw NotionBackendError.invalidTarget
        }
        let hasDatabaseView = components.queryItems?.contains { item in
            item.name == "v" && item.value.flatMap(normalizeID) != nil
        } == true
        return NotionTarget(kind: hint ?? (hasDatabaseView ? .database : .page), id: id)
    }

    private static func isNotionHost(_ host: String) -> Bool {
        host == "notion.so" || host.hasSuffix(".notion.so") ||
            host == "notion.site" || host.hasSuffix(".notion.site") ||
            host == "notion.com" || host.hasSuffix(".notion.com")
    }
}

// MARK: - Token isolation

protocol NotionTokenStore {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func clearToken() throws
}

enum NotionTokenStoreError: Error { case keychain(OSStatus), invalidToken }

struct KeychainNotionTokenStore: NotionTokenStore {
    static let service = "com.brianzheng.mimo"
    static let account = "mimo.notion.integration-token"

    private var lookup: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func readToken() throws -> String? {
        var query = lookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NotionTokenStoreError.keychain(status) }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              let valid = Self.validated(token) else { throw NotionTokenStoreError.invalidToken }
        return valid
    }

    func saveToken(_ token: String) throws {
        guard let value = Self.validated(token) else { throw NotionTokenStoreError.invalidToken }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updated = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NotionTokenStoreError.keychain(updated) }
        var item = lookup
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NotionTokenStoreError.keychain(added) }
    }

    func clearToken() throws {
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NotionTokenStoreError.keychain(status)
        }
    }

    private static func validated(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}

// MARK: - HTTP transport

protocol NotionTransport {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class EphemeralNotionTransport: NotionTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionBackendError.invalidResponse }
        return (data, http)
    }
}

enum NotionBackendError: Error, Equatable, LocalizedError {
    case invalidTarget
    case missingToken
    case network
    case forbidden
    case notFound
    case rateLimited
    case unauthorized
    case conflict
    case serverUnavailable
    case incompleteResults
    case partialContent
    case invalidResponse
    case unsupported
    case confirmationRequired

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "This is not a valid Notion page or data source."
        case .missingToken: return "Connect a Notion integration token to sync reflections."
        case .network: return "Mimo could not reach Notion. Your local reflections are unchanged."
        case .forbidden: return "The integration cannot access this Notion content (403)."
        case .notFound: return "Notion could not find this page or data source (404)."
        case .rateLimited: return "Notion is busy (429). Try syncing again shortly."
        case .unauthorized: return "The Notion token is invalid or expired (401)."
        case .conflict: return "Notion could not apply this change because the page changed (409)."
        case .serverUnavailable: return "Notion is temporarily unavailable. Cached reflections remain available."
        case .incompleteResults: return "This Notion data source exceeds the 10,000-row query limit. Narrow the source before syncing."
        case .partialContent: return "Notion returned only part of this page. Cached reflections remain available."
        case .invalidResponse: return "Notion returned an unreadable response."
        case .unsupported: return "This Notion content type is not supported yet."
        case .confirmationRequired: return "Preview and confirm before writing to Notion."
        }
    }
}

final class NotionHTTPClient {
    typealias Sleeper = (TimeInterval) async throws -> Void
    private let tokenStore: NotionTokenStore
    private let transport: NotionTransport
    private let maxRateLimitRetries: Int
    private let maximumRetryDelay: TimeInterval
    private let sleep: Sleeper

    init(tokenStore: NotionTokenStore, transport: NotionTransport,
         maxRateLimitRetries: Int = 1,
         maximumRetryDelay: TimeInterval = .greatestFiniteMagnitude,
         sleep: @escaping Sleeper = { seconds in
             guard seconds > 0 else { return }
             try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.tokenStore = tokenStore
        self.transport = transport
        self.maxRateLimitRetries = max(0, maxRateLimitRetries)
        self.maximumRetryDelay = max(0, maximumRetryDelay)
        self.sleep = sleep
    }

    func request(method: String, path: String, body: Any? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let token = try tokenStore.readToken(), !token.isEmpty else {
            throw NotionBackendError.missingToken
        }
        guard let url = URL(string: "https://api.notion.com/v1" + path) else {
            throw NotionBackendError.invalidTarget
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimoNotionAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        for attempt in 0...maxRateLimitRetries {
            let data: Data
            let response: HTTPURLResponse
            do { (data, response) = try await transport.execute(request) }
            catch let error as NotionBackendError { throw error }
            catch { throw NotionBackendError.network }
            try Task.checkCancellation()
            switch response.statusCode {
            case 200..<300: return data
            case 401: throw NotionBackendError.unauthorized
            case 403: throw NotionBackendError.forbidden
            case 404: throw NotionBackendError.notFound
            case 405, 501: throw NotionBackendError.unsupported
            case 409: throw NotionBackendError.conflict
            case 429:
                guard attempt < maxRateLimitRetries else { throw NotionBackendError.rateLimited }
                let requested = TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                try await sleep(min(max(0, requested), maximumRetryDelay))
                try Task.checkCancellation()
            case 500..<600: throw NotionBackendError.serverUnavailable
            default: throw NotionBackendError.invalidResponse
            }
        }
        throw NotionBackendError.rateLimited
    }
}

// MARK: - Content parsing

struct NotionMarkdownPage: Equatable {
    var markdown: String
    var unknownBlockIDs: [String]
    var truncated: Bool
}

enum NotionContentParser {
    static func markdownResponse(_ data: Data) throws -> NotionMarkdownPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let markdown = root["markdown"] as? String else { throw NotionBackendError.invalidResponse }
        return NotionMarkdownPage(
            markdown: markdown,
            unknownBlockIDs: root["unknown_block_ids"] as? [String] ?? [],
            truncated: root["truncated"] as? Bool ?? false)
    }

    static func richText(_ raw: Any?) -> String {
        guard let items = raw as? [[String: Any]] else { return "" }
        return items.compactMap { ($0["plain_text"] as? String) ??
            (($0["text"] as? [String: Any])?["content"] as? String) }.joined()
    }

    static func blocksToMarkdown(_ blocks: [[String: Any]], depth: Int = 0) -> String {
        var lines: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String,
                  let body = block[type] as? [String: Any] else { continue }
            let text = richText(body["rich_text"])
            let line: String?
            switch type {
            case "paragraph": line = text
            case "heading_1": line = "# \(text)"
            case "heading_2": line = "## \(text)"
            case "heading_3": line = "### \(text)"
            case "bulleted_list_item": line = "\(String(repeating: "  ", count: depth))- \(text)"
            case "numbered_list_item": line = "\(String(repeating: "  ", count: depth))1. \(text)"
            case "to_do": line = "\(String(repeating: "  ", count: depth))- [\((body["checked"] as? Bool) == true ? "x" : " ")] \(text)"
            case "quote": line = "> \(text)"
            case "code":
                let language = body["language"] as? String ?? ""
                line = "```\(language)\n\(text)\n```"
            case "callout": line = "> \(text)"
            case "toggle": line = "<details><summary>\(text)</summary></details>"
            case "divider": line = "---"
            case "child_page", "child_database":
                let title = body["title"] as? String ?? text
                line = title.isEmpty ? "[Notion \(type)]" : "[\(title)]"
            default:
                // A rare block type should remain visible as a recoverable gap
                // rather than disappearing from the imported source of truth.
                line = text.isEmpty ? "[Unsupported Notion block: \(type)]" : text
            }
            if let line { lines.append(line) }
            if let children = block["children"] as? [[String: Any]], !children.isEmpty {
                lines.append(blocksToMarkdown(children, depth: depth + 1))
            } else if let children = block["children_markdown"] as? String,
                      !children.isEmpty {
                // Recursive fallback content belongs immediately after its
                // parent, before the next sibling.
                lines.append(children)
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Sync records and cache

struct NotionPageRecord: Codable, Equatable {
    let pageID: String
    var title: String
    var date: Date?
    var kind: String
    var markdown: String
    var url: String
    var lastEditedAt: Date
    var syncedAt: Date
}

enum NotionSyncTrigger: String, Codable { case manual, launchRefresh }

struct NotionSyncSnapshot: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion: Int = Self.schemaVersion
    let apiVersion: String
    let target: NotionTarget
    let records: [NotionPageRecord]
    let syncedAt: Date
    let trigger: NotionSyncTrigger
}

extension NotionPageRecord {
    var reflectionModel: NotionReflection {
        let normalized = "\(kind) \(title)"
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type: ReflectionType
        if normalized.contains("week") || normalized.contains("周") { type = .weekly }
        else if normalized.contains("summar") || normalized.contains("总结") { type = .summary }
        else if normalized.contains("daily") || normalized.contains("day") || normalized.contains("日") { type = .daily }
        else { type = .unknown }
        return NotionReflection(id: "notion:\(pageID)", title: title,
                                reflectionDate: date, reflectionType: type,
                                markdown: markdown, pageID: pageID, pageURL: url,
                                lastEditedAt: lastEditedAt, syncedAt: syncedAt)
    }
}

extension NotionSyncSnapshot {
    var reflectionModels: [NotionReflection] { records.map(\.reflectionModel) }

    func syncState(sourceURL: String) -> NotionSyncState {
        NotionSyncState(
            sourceID: target.id, sourceURL: sourceURL, lastSyncedAt: syncedAt,
            lastEditedAtByPage: Dictionary(uniqueKeysWithValues: records.map { ($0.pageID, $0.lastEditedAt) }),
            cachedPageIDs: records.map(\.pageID), nextCursor: nil, hasMore: false, lastError: nil)
    }
}

final class NotionReflectionCache {
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    func load(for target: NotionTarget) -> NotionSyncSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder.mimoNotion.decode(NotionSyncSnapshot.self, from: data),
              value.schemaVersion == NotionSyncSnapshot.schemaVersion,
              value.apiVersion == mimoNotionAPIVersion,
              value.target == target else { return nil }
        return value
    }

    func save(_ snapshot: NotionSyncSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder.mimoNotion.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var mimoNotion: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = value.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var mimoNotion: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseNotionISO8601(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
            }
            return date
        }
        return decoder
    }
}

private final class NotionMarkdownContinuationContext {
    static let maximumDepth = 64
    static let maximumRequests = 500
    static let maximumUnknownBlocksPerResponse = 100

    var activeIDs = Set<String>()
    var renderedByID: [String: String] = [:]
    var unavailableIDs = Set<String>()
    var requestCount = 0
}

final class NotionReflectionService {
    private static let unknownTagExpression = try! NSRegularExpression(
        pattern: #"(?i)<unknown\b[^>]*?/\s*>"#)

    private let client: NotionHTTPClient
    private let cache: NotionReflectionCache
    private let now: () -> Date

    init(client: NotionHTTPClient, cache: NotionReflectionCache, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    func sync(target: NotionTarget, trigger: NotionSyncTrigger,
              persist: Bool = true) async throws -> NotionSyncSnapshot {
        try Task.checkCancellation()
        let previous = cache.load(for: target)
        var priorByID: [String: NotionPageRecord] = [:]
        for record in previous?.records ?? [] { priorByID[record.pageID] = record }
        let records: [NotionPageRecord]
        switch target.kind {
        case .page:
            records = [try await loadPage(id: target.id, previous: priorByID[target.id])]
        case .dataSource:
            records = try await loadDataSource(id: target.id, previous: priorByID)
        case .database:
            records = try await loadDatabase(id: target.id, previous: priorByID)
        }
        let snapshot = NotionSyncSnapshot(apiVersion: mimoNotionAPIVersion, target: target,
                                          records: records, syncedAt: now(), trigger: trigger)
        // Cancellation is a privacy boundary: target/token/delete changes must
        // not let an older request recreate a cache after the user moved on.
        if persist {
            try Task.checkCancellation()
            try cache.save(snapshot)
        }
        return snapshot
    }

    private func loadDatabase(id: String, previous: [String: NotionPageRecord]) async throws -> [NotionPageRecord] {
        let data = try await client.request(method: "GET", path: "/databases/\(id)")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = root["data_sources"] as? [[String: Any]], !sources.isEmpty else {
            throw NotionBackendError.invalidResponse
        }
        var all: [NotionPageRecord] = []
        var seenSourceIDs = Set<String>()
        for source in sources {
            try Task.checkCancellation()
            guard let rawID = source["id"] as? String,
                  let sourceID = NotionTargetParser.normalizeID(rawID),
                  seenSourceIDs.insert(sourceID).inserted else {
                throw NotionBackendError.invalidResponse
            }
            all += try await loadDataSource(id: sourceID, previous: previous)
        }
        guard Set(all.map(\.pageID)).count == all.count else {
            throw NotionBackendError.invalidResponse
        }
        return all.sorted { ($0.date ?? $0.lastEditedAt) > ($1.date ?? $1.lastEditedAt) }
    }

    private func loadDataSource(id: String, previous: [String: NotionPageRecord]) async throws -> [NotionPageRecord] {
        var cursor: String?
        var seenCursors = Set<String>()
        var pageCount = 0
        var rows: [[String: Any]] = []
        repeat {
            try Task.checkCancellation()
            pageCount += 1
            guard pageCount <= 100 else { throw NotionBackendError.incompleteResults }
            // Wiki data sources can also return data_source objects. This MVP
            // imports reflection pages only and fails closed on malformed rows.
            var body: [String: Any] = ["page_size": 100, "result_type": "page"]
            if let cursor { body["start_cursor"] = cursor }
            let data = try await client.request(method: "POST", path: "/data_sources/\(id)/query", body: body)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]],
                  let hasMore = root["has_more"] as? Bool else {
                throw NotionBackendError.invalidResponse
            }
            if ((root["request_status"] as? [String: Any])?["type"] as? String) == "incomplete" {
                throw NotionBackendError.incompleteResults
            }
            rows += results
            cursor = hasMore ? root["next_cursor"] as? String : nil
            if hasMore && cursor == nil { throw NotionBackendError.invalidResponse }
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw NotionBackendError.invalidResponse
            }
        } while cursor != nil

        var seenPageIDs = Set<String>()
        let metadataRows: [PageMetadata] = try rows.map { page in
            guard let metadata = parsePageMetadata(page),
                  seenPageIDs.insert(metadata.pageID).inserted else {
                throw NotionBackendError.invalidResponse
            }
            return metadata
        }
        var output: [NotionPageRecord] = []
        for metadata in metadataRows {
            try Task.checkCancellation()
            if let old = previous[metadata.pageID], old.lastEditedAt == metadata.lastEditedAt {
                var reused = old
                reused.syncedAt = now()
                output.append(reused)
            } else {
                output.append(try await loadPage(id: metadata.pageID, metadata: metadata, previous: nil))
            }
        }
        return output.sorted { ($0.date ?? $0.lastEditedAt) > ($1.date ?? $1.lastEditedAt) }
    }

    private struct PageMetadata {
        let pageID: String
        let title: String
        let date: Date?
        let kind: String
        let url: String
        let lastEditedAt: Date
    }

    private func loadPage(id: String, metadata supplied: PageMetadata? = nil,
                          previous: NotionPageRecord?) async throws -> NotionPageRecord {
        let metadata: PageMetadata
        if let supplied { metadata = supplied }
        else {
            let data = try await client.request(method: "GET", path: "/pages/\(id)")
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = parsePageMetadata(root) else { throw NotionBackendError.invalidResponse }
            metadata = parsed
        }
        if let previous, previous.lastEditedAt == metadata.lastEditedAt {
            var reused = previous
            reused.syncedAt = now()
            return reused
        }
        let markdown = try await fetchMarkdown(pageID: metadata.pageID)
        return NotionPageRecord(pageID: metadata.pageID, title: metadata.title, date: metadata.date,
                                kind: metadata.kind, markdown: markdown, url: metadata.url,
                                lastEditedAt: metadata.lastEditedAt, syncedAt: now())
    }

    private func fetchMarkdown(pageID: String) async throws -> String {
        do {
            let data = try await client.request(method: "GET", path: "/pages/\(pageID)/markdown")
            let parsed = try NotionContentParser.markdownResponse(data)
            let context = NotionMarkdownContinuationContext()
            if let rootID = NotionTargetParser.normalizeID(pageID) {
                context.activeIDs.insert(rootID)
            }
            return try await resolveUnknownMarkdown(in: parsed, depth: 0, context: context)
        } catch let error as NotionBackendError where error == .unsupported {
            // Older/fixture servers may not expose page-markdown. The standard
            // block endpoint remains a lossless supported fallback.
            return try await fetchBlockTree(parentID: pageID)
        }
    }

    private func resolveUnknownMarkdown(in page: NotionMarkdownPage, depth: Int,
                                        context: NotionMarkdownContinuationContext) async throws -> String {
        try Task.checkCancellation()
        guard depth <= NotionMarkdownContinuationContext.maximumDepth,
              page.unknownBlockIDs.count <= NotionMarkdownContinuationContext.maximumUnknownBlocksPerResponse
        else { throw NotionBackendError.partialContent }
        if page.truncated && page.unknownBlockIDs.isEmpty {
            throw NotionBackendError.partialContent
        }
        guard !page.unknownBlockIDs.isEmpty else { return page.markdown }

        let normalizedIDs = try page.unknownBlockIDs.map { rawID -> String in
            guard let id = NotionTargetParser.normalizeID(rawID) else {
                throw NotionBackendError.partialContent
            }
            return id
        }
        guard Set(normalizedIDs).count == normalizedIDs.count else {
            throw NotionBackendError.partialContent
        }

        let source = page.markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = Self.unknownTagExpression.matches(in: page.markdown, range: fullRange)
        var blockIDByMatch: [Int: String] = [:]
        var matchedIDs = Set<String>()
        for (index, match) in matches.enumerated() {
            let rawTag = source.substring(with: match.range)
            let searchableTag = (rawTag.removingPercentEncoding ?? rawTag)
                .lowercased().replacingOccurrences(of: "-", with: "")
            let candidates = normalizedIDs.filter {
                searchableTag.contains($0.replacingOccurrences(of: "-", with: ""))
            }
            guard candidates.count <= 1 else { throw NotionBackendError.partialContent }
            if let id = candidates.first {
                guard matchedIDs.insert(id).inserted else {
                    throw NotionBackendError.partialContent
                }
                blockIDByMatch[index] = id
            }
        }
        // Unsupported block types may also use <unknown> but are not guaranteed
        // to appear in unknown_block_ids. Only replace tags whose URL proves the
        // exact ID; otherwise preserve the source and fail closed.
        guard matchedIDs.count == normalizedIDs.count else {
            throw NotionBackendError.partialContent
        }

        var parts: [String] = []
        var cursor = 0
        for (index, match) in matches.enumerated() {
            try Task.checkCancellation()
            parts.append(source.substring(with: NSRange(
                location: cursor, length: match.range.location - cursor)))
            let placeholder = source.substring(with: match.range)
            if let blockID = blockIDByMatch[index],
               let continuation = try await continuationMarkdown(
                    blockID: blockID, depth: depth + 1, context: context) {
                parts.append(indentedContinuation(continuation, replacing: match.range, in: source))
            } else {
                // A 404 means this child is not shared with the integration.
                // Keeping the original tag makes the missing source visible.
                parts.append(placeholder)
            }
            cursor = NSMaxRange(match.range)
        }
        parts.append(source.substring(from: cursor))
        return parts.joined()
    }

    private func continuationMarkdown(blockID: String, depth: Int,
                                      context: NotionMarkdownContinuationContext) async throws -> String? {
        try Task.checkCancellation()
        guard depth <= NotionMarkdownContinuationContext.maximumDepth else {
            throw NotionBackendError.partialContent
        }
        if let rendered = context.renderedByID[blockID] { return rendered }
        if context.unavailableIDs.contains(blockID) { return nil }
        guard !context.activeIDs.contains(blockID) else {
            throw NotionBackendError.partialContent
        }
        context.requestCount += 1
        guard context.requestCount <= NotionMarkdownContinuationContext.maximumRequests else {
            throw NotionBackendError.partialContent
        }
        context.activeIDs.insert(blockID)
        defer { context.activeIDs.remove(blockID) }

        do {
            let data = try await client.request(method: "GET", path: "/pages/\(blockID)/markdown")
            let child = try NotionContentParser.markdownResponse(data)
            let rendered = try await resolveUnknownMarkdown(in: child, depth: depth, context: context)
            context.renderedByID[blockID] = rendered
            return rendered
        } catch let error as NotionBackendError where error == .notFound {
            context.unavailableIDs.insert(blockID)
            return nil
        }
    }

    private func indentedContinuation(_ continuation: String, replacing range: NSRange,
                                      in source: NSString) -> String {
        guard range.location > 0 else { return continuation }
        let preceding = NSRange(location: 0, length: range.location)
        let newline = source.range(of: "\n", options: .backwards, range: preceding)
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        let prefix = source.substring(with: NSRange(
            location: lineStart, length: range.location - lineStart))
        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return continuation }
        return continuation.replacingOccurrences(of: "\n", with: "\n" + prefix)
    }

    private func fetchBlockTree(parentID: String, depth: Int = 0) async throws -> String {
        guard depth <= 64 else { throw NotionBackendError.invalidResponse }
        var cursor: String?
        var seenCursors = Set<String>()
        var blocks: [[String: Any]] = []
        repeat {
            try Task.checkCancellation()
            var path = "/blocks/\(parentID)/children?page_size=100"
            if let cursor, let encoded = Self.encodeQueryValue(cursor) {
                path += "&start_cursor=\(encoded)"
            }
            let data = try await client.request(method: "GET", path: path)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]],
                  let hasMore = root["has_more"] as? Bool else {
                throw NotionBackendError.invalidResponse
            }
            for var block in results {
                if (block["has_children"] as? Bool) == true, let childID = block["id"] as? String {
                    let childMarkdown = try await fetchBlockTree(parentID: childID, depth: depth + 1)
                    if !childMarkdown.isEmpty { block["children_markdown"] = childMarkdown }
                }
                blocks.append(block)
            }
            cursor = hasMore ? root["next_cursor"] as? String : nil
            if hasMore && cursor == nil { throw NotionBackendError.invalidResponse }
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw NotionBackendError.invalidResponse
            }
        } while cursor != nil
        return NotionContentParser.blocksToMarkdown(blocks)
    }

    private func parsePageMetadata(_ page: [String: Any]) -> PageMetadata? {
        guard let rawID = page["id"] as? String,
              let id = NotionTargetParser.normalizeID(rawID),
              let editedRaw = page["last_edited_time"] as? String,
              let edited = parseNotionISO8601(editedRaw) else { return nil }
        let properties = page["properties"] as? [String: Any] ?? [:]
        var title = "Untitled"
        var date: Date?
        var kind = "Reflection"
        for (name, raw) in properties {
            guard let property = raw as? [String: Any], let type = property["type"] as? String else { continue }
            if type == "title" {
                let value = NotionContentParser.richText(property["title"])
                if !value.isEmpty { title = value }
            } else if type == "date", date == nil,
                      let start = (property["date"] as? [String: Any])?["start"] as? String {
                date = parseNotionDate(start)
            } else if type == "select",
                      (name.lowercased().contains("type") || name.contains("类型")),
                      let value = (property["select"] as? [String: Any])?["name"] as? String {
                kind = value
            }
        }
        return PageMetadata(pageID: id, title: title, date: date, kind: kind,
                            url: page["url"] as? String ?? "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))",
                            lastEditedAt: edited)
    }

    private func parseNotionDate(_ value: String) -> Date? {
        if let date = parseNotionISO8601(value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func encodeQueryValue(_ value: String) -> String? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

// MARK: - Writeback preview and confirmation gate

enum NotionWritebackDestination: Codable, Equatable {
    case appendToPage(pageID: String)
    case createPage(parentPageID: String, title: String)
}

struct NotionWritebackPreview: Codable, Equatable {
    let draftID: String
    let destination: NotionWritebackDestination
    let dateRange: String
    let source: String
    let evidenceIDs: [String]
    let markdown: String
    let idempotencyKey: String
}

enum NotionWritebackPreviewBuilder {
    static func build(draftID: String, destination: NotionWritebackDestination,
                      dateRange: String, source: String, evidenceIDs: [String],
                      synthesisMarkdown: String) -> NotionWritebackPreview {
        let evidence = evidenceIDs.sorted()
        let markdown = """
        ## Mimo Synthesis

        - **Date range:** \(dateRange)
        - **Source:** \(source)
        - **Evidence:** \(evidence.joined(separator: ", "))

        \(synthesisMarkdown)
        """
        let destinationText: String
        switch destination {
        case .appendToPage(let id): destinationText = "append:\(id)"
        case .createPage(let id, let title): destinationText = "create:\(id):\(title)"
        }
        let canonical = [draftID, destinationText, dateRange, source, evidence.joined(separator: "|"), synthesisMarkdown]
            .joined(separator: "\u{1f}")
        return NotionWritebackPreview(draftID: draftID, destination: destination,
                                      dateRange: dateRange, source: source, evidenceIDs: evidence,
                                      markdown: markdown, idempotencyKey: stableNotionHash(canonical))
    }

    static func build(draft: SynthesisDraft, source: String) throws -> NotionWritebackPreview {
        guard let pageID = draft.targetPageID.flatMap(NotionTargetParser.normalizeID) else {
            throw NotionBackendError.invalidTarget
        }
        let destination: NotionWritebackDestination
        switch draft.target {
        case .appendPage: destination = .appendToPage(pageID: pageID)
        case .createPage: destination = .createPage(parentPageID: pageID, title: draft.title)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let inclusiveEnd = max(draft.dateRange.start,
                               draft.dateRange.end.addingTimeInterval(-0.001))
        let range = "\(formatter.string(from: draft.dateRange.start)) → \(formatter.string(from: inclusiveEnd))"
        let generated = build(draftID: draft.id, destination: destination, dateRange: range,
                              source: source, evidenceIDs: draft.evidenceIDs,
                              synthesisMarkdown: draft.markdown)
        // The final preview may have a different destination or extra evidence
        // links/marks than the base synthesis draft. Its idempotency key must
        // always bind the exact confirmed scope and content.
        return generated
    }

    private static func stableNotionHash(_ value: String) -> String {
        // FNV-1a is deterministic across launches; this is an idempotency key,
        // not a credential or security primitive.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
}

enum NotionWritebackOutcome: Equatable {
    case confirmationRequired(NotionWritebackPreview)
    case inProgress(NotionWritebackPreview)
    case written(NotionWritebackPreview)
    case alreadyWritten(NotionWritebackPreview)
    case failed(NotionWritebackPreview, NotionBackendError)
}

actor NotionWritebackExecutor {
    private let client: NotionHTTPClient
    private var successfulKeys: Set<String>
    private var inFlightKeys: Set<String> = []
    private let ledgerURL: URL?

    init(client: NotionHTTPClient, successfulKeys: Set<String> = [], ledgerURL: URL? = nil) {
        self.client = client
        self.ledgerURL = ledgerURL
        var restored = successfulKeys
        if let ledgerURL, let data = try? Data(contentsOf: ledgerURL),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            restored.formUnion(values)
        }
        self.successfulKeys = restored
    }

    func execute(_ preview: NotionWritebackPreview, confirmed: Bool) async -> NotionWritebackOutcome {
        guard confirmed else { return .confirmationRequired(preview) }
        if successfulKeys.contains(preview.idempotencyKey) { return .alreadyWritten(preview) }
        guard inFlightKeys.insert(preview.idempotencyKey).inserted else {
            return .inProgress(preview)
        }
        defer { inFlightKeys.remove(preview.idempotencyKey) }
        do {
            switch preview.destination {
            case .appendToPage(let pageID):
                let marker = Self.remoteMarker(for: preview.idempotencyKey)
                if try await pageContainsMarker(pageID: pageID, marker: marker) {
                    successfulKeys.insert(preview.idempotencyKey)
                    persistLedger()
                    return .alreadyWritten(preview)
                }
                try Task.checkCancellation()
                let body: [String: Any] = [
                    "type": "insert_content",
                    "insert_content": [
                        "content": preview.markdown + "\n\n" + marker,
                        "position": ["type": "end"],
                    ],
                ]
                let response = try await client.request(
                    method: "PATCH", path: "/pages/\(pageID)/markdown", body: body)
                let updatedPage = try NotionContentParser.markdownResponse(response)
                guard try await markdownPageContainsMarker(updatedPage, marker: marker) else {
                    // A 2xx response is not enough: only persist success after
                    // Notion proves the durable marker survived normalization,
                    // including a truncated response's continuation subtrees.
                    throw NotionBackendError.invalidResponse
                }
                try Task.checkCancellation()
            case .createPage:
                // The MVP deliberately exposes append-only writeback. Creating
                // a child page cannot be made restart-idempotent without a
                // remote lookup/index, so fail closed until OAuth/webhooks add
                // that durable destination model.
                throw NotionBackendError.unsupported
            }
            successfulKeys.insert(preview.idempotencyKey)
            persistLedger()
            return .written(preview)
        } catch let error as NotionBackendError {
            return .failed(preview, error)
        } catch {
            return .failed(preview, .network)
        }
    }

    private func persistLedger() {
        guard let ledgerURL else { return }
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(successfulKeys.sorted())
            try data.write(to: ledgerURL, options: .atomic)
        } catch {
            // The remote write has already succeeded. Keep the in-memory key so
            // this process remains idempotent; never log draft content or URL.
        }
    }

    private func pageContainsMarker(pageID: String, marker: String) async throws -> Bool {
        let data = try await client.request(method: "GET", path: "/pages/\(pageID)/markdown")
        let page = try NotionContentParser.markdownResponse(data)
        return try await markdownPageContainsMarker(page, marker: marker)
    }

    private func markdownPageContainsMarker(_ root: NotionMarkdownPage,
                                            marker: String) async throws -> Bool {
        if root.markdown.contains(marker) { return true }
        if root.truncated && root.unknownBlockIDs.isEmpty {
            throw NotionBackendError.partialContent
        }
        var pending = root.unknownBlockIDs
        var visited = Set<String>()
        while !pending.isEmpty {
            try Task.checkCancellation()
            let id = pending.removeFirst()
            guard visited.insert(id).inserted else { continue }
            guard visited.count <= 500 else { throw NotionBackendError.partialContent }
            do {
                let data = try await client.request(method: "GET", path: "/pages/\(id)/markdown")
                let page = try NotionContentParser.markdownResponse(data)
                if page.markdown.contains(marker) { return true }
                if page.truncated && page.unknownBlockIDs.isEmpty {
                    throw NotionBackendError.partialContent
                }
                pending.append(contentsOf: page.unknownBlockIDs)
            } catch let error as NotionBackendError where error == .notFound {
                // During sync an inaccessible continuation can remain a
                // visible gap. During idempotency preflight it is ambiguous:
                // the durable marker may be inside that unseen subtree. Fail
                // closed instead of risking a duplicate append.
                throw NotionBackendError.partialContent
            }
        }
        return false
    }

    private static func remoteMarker(for key: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        // Keep this in the documented Enhanced Markdown subset. Notion may
        // discard unsupported HTML comments, while inline code round-trips.
        return "Mimo writeback ID: `mimo-writeback-\(String(format: "%016llx", hash))`"
    }
}
