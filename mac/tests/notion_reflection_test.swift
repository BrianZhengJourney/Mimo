// sources: reflection_core.swift notion_reflection.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message) (\(file):\(line))\n".utf8))
        exit(1)
    }
}

private func expectThrows(_ expected: NotionBackendError, _ message: String,
                          operation: () throws -> Void) {
    do { try operation(); expect(false, message) }
    catch let error as NotionBackendError { expect(error == expected, message) }
    catch { expect(false, "\(message): wrong error \(error)") }
}

private final class SpyTokenStore: NotionTokenStore {
    var token: String?
    var reads = 0
    var saves: [String] = []
    init(_ token: String?) { self.token = token }
    func readToken() throws -> String? { reads += 1; return token }
    func saveToken(_ token: String) throws { saves.append(token); self.token = token }
    func clearToken() throws { token = nil }
}

private struct StubFailure: Error {}

private final class QueueTransport: NotionTransport {
    enum Item { case response(Int, Data, [String: String]); case failure }
    var items: [Item]
    var requests: [URLRequest] = []
    let delayNanoseconds: UInt64
    init(_ items: [Item], delayNanoseconds: UInt64 = 0) {
        self.items = items
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        requests.append(request)
        guard !items.isEmpty else { throw StubFailure() }
        switch items.removeFirst() {
        case .failure: throw StubFailure()
        case .response(let status, let data, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            return (data, response)
        }
    }

    static func json(_ status: Int = 200, _ value: Any,
                     headers: [String: String] = [:]) -> Item {
        .response(status, try! JSONSerialization.data(withJSONObject: value), headers)
    }
}

private actor RateLimitCancellationTransport: NotionTransport {
    private var count = 0

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let status = count == 1 ? 429 : 200
        let headers = count == 1 ? ["Retry-After": "60"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data("{}".utf8), response)
    }

    func requestCount() -> Int { count }
}

private func temporaryURL(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mimo-notion-tests", isDirectory: true)
        .appendingPathComponent(name + ".json")
}

private let pageA = "11111111-1111-1111-1111-111111111111"
private let pageB = "22222222-2222-2222-2222-222222222222"
private let pageC = "33333333-3333-3333-3333-333333333333"

private func unknownTag(_ blockID: String, alt: String? = nil) -> String {
    let compact = blockID.replacingOccurrences(of: "-", with: "")
    let altAttribute = alt.map { " alt=\"\($0)\"" } ?? ""
    return "<unknown url=\"https://notion.so/reflection#\(compact)\"\(altAttribute)/>"
}

private func writebackMarker(for key: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return "Mimo writeback ID: `mimo-writeback-\(String(format: "%016llx", hash))`"
}

private func pageRow(id: String, edited: String, title: String) -> [String: Any] {
    [
        "id": id,
        "last_edited_time": edited,
        "url": "https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))",
        "properties": [
            "Name": ["type": "title", "title": [["plain_text": title]]],
            "Date": ["type": "date", "date": ["start": "2026-08-02"]],
            "Type": ["type": "select", "select": ["name": "Daily"]],
        ],
    ]
}

private func testTargetParsing() {
    let compact = "0123456789abcdef0123456789abcdef"
    let normalized = "01234567-89ab-cdef-0123-456789abcdef"
    expect(NotionTargetParser.normalizeID(compact) == normalized, "32-hex ID normalizes")
    expect(NotionTargetParser.normalizeID(normalized.uppercased()) == normalized, "UUID normalizes")
    expectThrows(.invalidTarget, "a bare ID without its type is ambiguous") {
        _ = try NotionTargetParser.parse(compact)
    }
    expect(try! NotionTargetParser.parse(compact, hint: .page) == NotionTarget(kind: .page, id: normalized),
           "a hinted bare page ID parses")
    expect(try! NotionTargetParser.parse("data_source:\(compact)").kind == .dataSource,
           "direct data source ID parses")
    expect(try! NotionTargetParser.parse("https://www.notion.so/Journal-\(compact)?v=abc").id == normalized,
           "notion.so page URL parses terminal ID")
    expect(try! NotionTargetParser.parse("https://www.notion.so/Journal-\(compact)?v=\(compact)").kind == .database,
           "database URL with a Notion view ID is recognized")
    expect(try! NotionTargetParser.parse("https://notes.notion.site/Journal-\(compact)").kind == .page,
           "notion.site public URL parses")
    expect(try! NotionTargetParser.parse("https://notes.notion.site/Journal-\(normalized)").id == normalized,
           "slug URL with dashed UUID parses")
    expect(try! NotionTargetParser.parse("https://www.notion.com/Journal-\(compact)").kind == .page,
           "current notion.com URL parses")
    expect(try! NotionTargetParser.parse("https://www.notion.so/data_sources/\(compact)").kind == .dataSource,
           "data source URL parses")
    expect(try! NotionTargetParser.parse("https://www.notion.so/Journal-\(compact)", hint: .database).kind == .database,
           "database URL honors explicit kind")
    expectThrows(.invalidTarget, "foreign hosts are rejected") {
        _ = try NotionTargetParser.parse("https://evil.example/\(compact)")
    }
    expectThrows(.invalidTarget, "invalid or embedded IDs are rejected") {
        _ = try NotionTargetParser.parse("https://notion.so/not-a-valid-id")
    }
}

private func testMarkdownAndBlocks() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "markdown": "# Reflection", "truncated": true, "unknown_block_ids": [pageA],
    ])
    let page = try NotionContentParser.markdownResponse(data)
    expect(page.markdown == "# Reflection" && page.truncated && page.unknownBlockIDs == [pageA],
           "markdown-first response preserves truncation metadata")

    func rich(_ text: String) -> [[String: Any]] { [["plain_text": text]] }
    let blocks: [[String: Any]] = [
        ["type": "heading_1", "heading_1": ["rich_text": rich("Day")]],
        ["type": "paragraph", "paragraph": ["rich_text": rich("Worked deeply")]],
        ["type": "bulleted_list_item", "bulleted_list_item": ["rich_text": rich("One")]],
        ["type": "numbered_list_item", "numbered_list_item": ["rich_text": rich("Two")]],
        ["type": "to_do", "to_do": ["rich_text": rich("Done"), "checked": true]],
        ["type": "quote", "quote": ["rich_text": rich("Remember")]],
        ["type": "code", "code": ["rich_text": rich("let x = 1"), "language": "swift"]],
        ["type": "callout", "callout": ["rich_text": rich("Notice")]],
        ["type": "toggle", "toggle": ["rich_text": rich("Details")]],
        ["type": "bookmark", "bookmark": ["url": "https://example.com"]],
    ]
    let markdown = NotionContentParser.blocksToMarkdown(blocks)
    for fragment in ["# Day", "Worked deeply", "- One", "1. Two", "- [x] Done",
                     "> Remember", "```swift", "> Notice", "<details><summary>Details",
                     "[Unsupported Notion block: bookmark]"] {
        expect(markdown.contains(fragment), "block parser contains \(fragment)")
    }
    let ordered = NotionContentParser.blocksToMarkdown([
        ["type": "paragraph", "paragraph": ["rich_text": rich("Parent one")],
         "children_markdown": "> Child in place"],
        ["type": "paragraph", "paragraph": ["rich_text": rich("Parent two")]],
    ])
    expect(ordered.range(of: "Parent one")!.lowerBound < ordered.range(of: "Child in place")!.lowerBound
           && ordered.range(of: "Child in place")!.lowerBound < ordered.range(of: "Parent two")!.lowerBound,
           "recursive child Markdown remains between its parent and next sibling")

    let inferred = NotionPageRecord(
        pageID: pageA, title: "Daily Reflection", date: nil, kind: "Reflection",
        markdown: "Body", url: "https://notion.so/\(pageA)",
        lastEditedAt: Date(), syncedAt: Date()).reflectionModel
    expect(inferred.reflectionType == .daily,
           "standalone page title participates in reflection type inference")
}

private func testHTTPFailures() async {
    do {
        let client = NotionHTTPClient(tokenStore: SpyTokenStore(nil), transport: QueueTransport([]))
        _ = try await client.request(method: "GET", path: "/pages/\(pageA)")
        expect(false, "missing token must fail")
    } catch let error as NotionBackendError { expect(error == .missingToken, "missing token maps cleanly") }
    catch { expect(false, "wrong missing-token error") }

    do {
        let client = NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                      transport: QueueTransport([.failure]))
        _ = try await client.request(method: "GET", path: "/pages/\(pageA)")
        expect(false, "network must fail")
    } catch let error as NotionBackendError { expect(error == .network, "network error maps cleanly") }
    catch { expect(false, "wrong network error") }

    for (status, expected) in [(401, NotionBackendError.unauthorized),
                               (403, .forbidden), (404, .notFound),
                               (409, .conflict), (503, .serverUnavailable)] {
        do {
            let client = NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                          transport: QueueTransport([QueueTransport.json(status, [:])]))
            _ = try await client.request(method: "GET", path: "/test")
            expect(false, "HTTP \(status) must fail")
        } catch let error as NotionBackendError { expect(error == expected, "HTTP \(status) maps") }
        catch { expect(false, "wrong HTTP \(status) error") }
    }

    var slept: [TimeInterval] = []
    let rateTransport = QueueTransport([
        QueueTransport.json(429, [:], headers: ["Retry-After": "99"]), QueueTransport.json(429, [:]),
    ])
    do {
        let client = NotionHTTPClient(tokenStore: SpyTokenStore("secret"), transport: rateTransport,
                                      maxRateLimitRetries: 1, maximumRetryDelay: 0.25,
                                      sleep: { slept.append($0) })
        _ = try await client.request(method: "GET", path: "/test")
        expect(false, "exhausted 429 must fail")
    } catch let error as NotionBackendError { expect(error == .rateLimited, "429 maps") }
    catch { expect(false, "wrong 429 error") }
    expect(slept == [0.25] && rateTransport.requests.count == 2,
           "Retry-After is honored but bounded and retry count is bounded")

    let cancellationTransport = RateLimitCancellationTransport()
    let cancellationClient = NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: cancellationTransport,
        maxRateLimitRetries: 1)
    let retrying = Task {
        try await cancellationClient.request(method: "GET", path: "/cancel-test")
    }
    while await cancellationTransport.requestCount() == 0 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 5_000_000)
    retrying.cancel()
    do {
        _ = try await retrying.value
        expect(false, "cancelled rate-limit backoff must not complete")
    } catch is CancellationError {
        // Expected: cancellation is a privacy boundary for the old request.
    } catch {
        expect(false, "cancelled rate-limit backoff preserves CancellationError")
    }
    let requestCountAfterCancellation = await cancellationTransport.requestCount()
    expect(requestCountAfterCancellation == 1,
           "cancelling during Retry-After never sends the queued retry")
}

private func testPaginationIncrementalCacheAndTokenIsolation() async throws {
    let token = "super-secret-token-never-on-disk"
    let store = SpyTokenStore(token)
    let firstTransport = QueueTransport([
        QueueTransport.json(200, ["results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.123Z", title: "A")],
                    "has_more": true, "next_cursor": "cursor-2"]),
        QueueTransport.json(200, ["results": [pageRow(id: pageB, edited: "2026-08-01T11:00:00.000Z", title: "B")],
                    "has_more": false]),
        QueueTransport.json(200, ["markdown": "A body", "truncated": false]),
        QueueTransport.json(200, ["markdown": "B body", "truncated": false]),
    ])
    let cacheURL = temporaryURL("sync-\(UUID().uuidString)")
    let cache = NotionReflectionCache(fileURL: cacheURL)
    let target = NotionTarget(kind: .dataSource, id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    let fixedNow = ISO8601DateFormatter().date(from: "2026-08-02T01:00:00Z")!
    let first = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: store, transport: firstTransport),
        cache: cache, now: { fixedNow }).sync(target: target, trigger: .manual)
    expect(first.records.count == 2, "all data source pages are collected across pagination")
    expect(first.records.map { $0.markdown }.sorted() == ["A body", "B body"], "page markdown fetched")
    expect(firstTransport.requests[1].httpBody.flatMap {
        (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["start_cursor"] as? String
    } == "cursor-2", "next cursor is sent")
    let cachedText = try String(contentsOf: cacheURL, encoding: .utf8)
    expect(cachedText.contains(token) == false, "token never enters disk cache")

    let secondTransport = QueueTransport([
        QueueTransport.json(200, ["results": [
            pageRow(id: pageA, edited: "2026-08-01T10:00:00.123Z", title: "A"),
            pageRow(id: pageB, edited: "2026-08-01T11:00:00.000Z", title: "B"),
        ], "has_more": false]),
    ])
    let second = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: store, transport: secondTransport),
        cache: cache, now: { fixedNow.addingTimeInterval(60) })
        .sync(target: target, trigger: .launchRefresh)
    expect(second.records.map { $0.markdown }.sorted() == ["A body", "B body"],
           "unchanged pages reuse cached markdown")
    expect(secondTransport.requests.count == 1, "incremental sync does not refetch unchanged page bodies")
    expect(second.trigger == NotionSyncTrigger.launchRefresh, "launch and manual refresh share one API and record trigger")

    let deletedTransport = QueueTransport([QueueTransport.json(200, [
        "results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.123Z", title: "A")],
        "has_more": false,
    ])])
    let afterDeletion = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: store, transport: deletedTransport),
        cache: cache, now: { fixedNow.addingTimeInterval(120) })
        .sync(target: target, trigger: .manual)
    expect(afterDeletion.records.map(\.pageID) == [pageA]
           && deletedTransport.requests.count == 1,
           "pages removed from the selected data source disappear from the atomic cache")

    let wrongTarget = NotionTarget(kind: .page, id: pageA)
    expect(cache.load(for: wrongTarget) == nil, "target change invalidates cache")

    let obsolete = NotionSyncSnapshot(schemaVersion: NotionSyncSnapshot.schemaVersion,
        apiVersion: "obsolete", target: target, records: [], syncedAt: fixedNow, trigger: .manual)
    try cache.save(obsolete)
    expect(cache.load(for: target) == nil, "API version change invalidates cache")
    try Data("corrupt".utf8).write(to: cacheURL, options: .atomic)
    expect(cache.load(for: target) == nil, "corrupt cache fails closed")
}

private func testDatabaseResolvesCurrentDataSources() async throws {
    let databaseID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    let sourceA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let sourceB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    let transport = QueueTransport([
        QueueTransport.json(200, ["data_sources": [["id": sourceA], ["id": sourceB]]]),
        QueueTransport.json(200, [
            "results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A")],
            "has_more": false,
        ]),
        QueueTransport.json(200, ["markdown": "Database A", "truncated": false]),
        QueueTransport.json(200, [
            "results": [pageRow(id: pageB, edited: "2026-08-01T11:00:00.000Z", title: "B")],
            "has_more": false,
        ]),
        QueueTransport.json(200, ["markdown": "Database B", "truncated": false]),
    ])
    let snapshot = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"), transport: transport),
        cache: NotionReflectionCache(fileURL: temporaryURL("database-\(UUID().uuidString)")))
        .sync(target: NotionTarget(kind: .database, id: databaseID), trigger: .manual)
    expect(snapshot.records.map(\.pageID).sorted() == [pageA, pageB],
           "database discovery imports pages from every current data source")
    expect(transport.requests.map { $0.url!.path } == [
        "/v1/databases/\(databaseID)",
        "/v1/data_sources/\(sourceA)/query", "/v1/pages/\(pageA)/markdown",
        "/v1/data_sources/\(sourceB)/query", "/v1/pages/\(pageB)/markdown",
    ], "database sync uses the current database, data source, and Markdown routes")
    for request in [transport.requests[1], transport.requests[3]] {
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        expect(body?["result_type"] as? String == "page",
               "wiki data source queries explicitly request page results")
    }

    let invalidCacheURL = temporaryURL("database-invalid-\(UUID().uuidString)")
    let malformed = QueueTransport([
        QueueTransport.json(200, ["data_sources": [["id": "not-a-notion-id"]]]),
    ])
    do {
        _ = try await NotionReflectionService(
            client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"), transport: malformed),
            cache: NotionReflectionCache(fileURL: invalidCacheURL))
            .sync(target: NotionTarget(kind: .database, id: databaseID), trigger: .manual)
        expect(false, "malformed database data source must fail closed")
    } catch let error as NotionBackendError {
        expect(error == .invalidResponse, "malformed database discovery is an invalid response")
    }
    expect(!FileManager.default.fileExists(atPath: invalidCacheURL.path),
           "malformed database discovery never replaces cache")

    let duplicateCacheURL = temporaryURL("database-duplicate-\(UUID().uuidString)")
    let duplicateAcrossSources = QueueTransport([
        QueueTransport.json(200, ["data_sources": [["id": sourceA], ["id": sourceB]]]),
        QueueTransport.json(200, [
            "results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A")],
            "has_more": false,
        ]),
        QueueTransport.json(200, ["markdown": "A from source A", "truncated": false]),
        QueueTransport.json(200, [
            "results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A")],
            "has_more": false,
        ]),
        QueueTransport.json(200, ["markdown": "A from source B", "truncated": false]),
    ])
    do {
        _ = try await NotionReflectionService(
            client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                     transport: duplicateAcrossSources),
            cache: NotionReflectionCache(fileURL: duplicateCacheURL))
            .sync(target: NotionTarget(kind: .database, id: databaseID), trigger: .manual)
        expect(false, "a page repeated across database data sources must fail closed")
    } catch let error as NotionBackendError {
        expect(error == .invalidResponse, "cross-source duplicate page is invalid")
    }
    expect(!FileManager.default.fileExists(atPath: duplicateCacheURL.path),
           "cross-source duplicate page never creates a cache")
}

private func testIncompletePaginationFailsClosed() async {
    let target = NotionTarget(kind: .dataSource,
                              id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    let cacheURL = temporaryURL("incomplete-\(UUID().uuidString)")
    let transport = QueueTransport([QueueTransport.json(200, [
        "results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A")],
        "has_more": false,
        "request_status": ["type": "incomplete",
                           "incomplete_reason": "query_result_limit_reached"],
    ])])
    do {
        _ = try await NotionReflectionService(
            client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                     transport: transport),
            cache: NotionReflectionCache(fileURL: cacheURL))
            .sync(target: target, trigger: .manual)
        expect(false, "10,000-row truncated query must not become a complete cache")
    } catch let error as NotionBackendError {
        expect(error == .incompleteResults, "incomplete query has a dedicated recoverable error")
    } catch { expect(false, "incomplete query returned the wrong error") }
    expect(!FileManager.default.fileExists(atPath: cacheURL.path),
           "incomplete query never replaces the cache")

    let malformedPayloads: [[String: Any]] = [
        ["results": [pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A")]],
        ["results": [
            pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A"),
            pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "A duplicate"),
        ], "has_more": false],
    ]
    for (index, payload) in malformedPayloads.enumerated() {
        let malformedCacheURL = temporaryURL("malformed-page-\(index)-\(UUID().uuidString)")
        do {
            _ = try await NotionReflectionService(
                client: NotionHTTPClient(
                    tokenStore: SpyTokenStore("secret"),
                    transport: QueueTransport([QueueTransport.json(200, payload)])),
                cache: NotionReflectionCache(fileURL: malformedCacheURL))
                .sync(target: target, trigger: .manual)
            expect(false, "malformed or duplicate query rows must fail closed")
        } catch let error as NotionBackendError {
            expect(error == .invalidResponse,
                   "malformed or duplicate query rows are invalid responses")
        } catch { expect(false, "malformed query returned the wrong error") }
        expect(!FileManager.default.fileExists(atPath: malformedCacheURL.path),
               "malformed query never creates a cache")
    }
}

private func testFallbackRecursion() async throws {
    let row = pageRow(id: pageA, edited: "2026-08-01T10:00:00.000Z", title: "Fallback")
    let transport = QueueTransport([
        QueueTransport.json(200, row),
        QueueTransport.json(405, [:]),
        QueueTransport.json(200, ["results": [[
            "id": pageB, "type": "paragraph", "has_children": true,
            "paragraph": ["rich_text": [["plain_text": "Parent one"]]],
        ]], "has_more": true, "next_cursor": "blocks-2"]),
        QueueTransport.json(200, ["results": [[
            "id": "33333333-3333-3333-3333-333333333333", "type": "quote", "has_children": false,
            "quote": ["rich_text": [["plain_text": "Child"]]],
        ]], "has_more": false]),
        QueueTransport.json(200, ["results": [[
            "id": "44444444-4444-4444-4444-444444444444",
            "type": "paragraph", "has_children": false,
            "paragraph": ["rich_text": [["plain_text": "Parent two"]]],
        ]], "has_more": false]),
    ])
    let cache = NotionReflectionCache(fileURL: temporaryURL())
    let snapshot = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"), transport: transport), cache: cache)
        .sync(target: NotionTarget(kind: .page, id: pageA), trigger: .manual)
    let markdown = snapshot.records[0].markdown
    expect(markdown.contains("Parent one") && markdown.contains("Child"),
           "unsupported markdown endpoint falls back to recursive block children")
    expect(markdown.range(of: "Parent one")!.lowerBound < markdown.range(of: "Child")!.lowerBound
           && markdown.range(of: "Child")!.lowerBound < markdown.range(of: "Parent two")!.lowerBound,
           "block fallback preserves parent-child-sibling order")
    expect(transport.requests.last?.url?.query?.contains("start_cursor=blocks-2") == true,
           "block fallback follows its cursor pagination")

    let denied = "55555555-5555-5555-5555-555555555555"
    let deniedPlaceholder = unknownTag(denied, alt: "child_page")
    let unsupportedPlaceholder = "<unknown url=\"https://notion.so/bookmark\" alt=\"bookmark\"/>"
    let continuationTransport = QueueTransport([
        QueueTransport.json(200, row),
        QueueTransport.json(200, [
            "markdown": "Root before\n\n\t\(unknownTag(pageB))\n\nRoot between\n\n"
                + unsupportedPlaceholder + "\n\n" + deniedPlaceholder + "\n\nRoot after",
            "truncated": true, "unknown_block_ids": [pageB, denied],
        ]),
        QueueTransport.json(200, [
            "markdown": "Child before\n\n\t\(unknownTag(pageC))\n\nChild after",
            "truncated": true, "unknown_block_ids": [pageC],
        ]),
        QueueTransport.json(200, [
            "markdown": "Recovered nested Markdown", "truncated": false,
            "unknown_block_ids": [],
        ]),
        QueueTransport.json(404, [:]),
    ])
    let continued = try await NotionReflectionService(
        client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                 transport: continuationTransport),
        cache: NotionReflectionCache(fileURL: temporaryURL()))
        .sync(target: NotionTarget(kind: .page, id: pageA), trigger: .manual)
    let continuedMarkdown = continued.records[0].markdown
    for fragment in ["Root before", "Child before", "Recovered nested Markdown",
                     "Child after", "Root between", unsupportedPlaceholder,
                     deniedPlaceholder, "Root after"] {
        expect(continuedMarkdown.contains(fragment), "continued Markdown contains \(fragment)")
    }
    let orderedFragments = ["Root before", "Child before", "Recovered nested Markdown",
                            "Child after", "Root between", unsupportedPlaceholder,
                            deniedPlaceholder, "Root after"]
    let orderedRanges = orderedFragments.map { continuedMarkdown.range(of: $0)! }
    expect(zip(orderedRanges, orderedRanges.dropFirst()).allSatisfy {
        $0.0.upperBound < $0.1.lowerBound
    },
           "nested continuations replace their exact parent placeholders in source order")
    expect(continuedMarkdown.contains("\tChild before")
           && continuedMarkdown.contains("\t\tRecovered nested Markdown"),
           "continuation replacement preserves parent indentation")
    expect(!continuedMarkdown.contains(unknownTag(pageB))
           && !continuedMarkdown.contains(unknownTag(pageC)),
           "resolved continuation placeholders are removed")
    expect(continuedMarkdown.contains(deniedPlaceholder),
           "permission-denied continuation keeps its visible placeholder")
    expect(continuedMarkdown.contains(unsupportedPlaceholder),
           "unsupported unknown tags outside unknown_block_ids remain untouched")
    expect(continuationTransport.requests[2].url?.path == "/v1/pages/\(pageB)/markdown"
           && continuationTransport.requests[3].url?.path == "/v1/pages/\(pageC)/markdown"
           && continuationTransport.requests[4].url?.path == "/v1/pages/\(denied)/markdown",
           "nested unknown IDs use /pages/{id}/markdown and permission 404 remains non-fatal")

    let cyclicTransport = QueueTransport([
        QueueTransport.json(200, row),
        QueueTransport.json(200, [
            "markdown": unknownTag(pageB), "truncated": true,
            "unknown_block_ids": [pageB],
        ]),
        QueueTransport.json(200, [
            "markdown": unknownTag(pageB), "truncated": true,
            "unknown_block_ids": [pageB],
        ]),
    ])
    do {
        _ = try await NotionReflectionService(
            client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                     transport: cyclicTransport),
            cache: NotionReflectionCache(fileURL: temporaryURL()))
            .sync(target: NotionTarget(kind: .page, id: pageA), trigger: .manual)
        expect(false, "cyclic Markdown continuations must fail closed")
    } catch let error as NotionBackendError {
        expect(error == .partialContent, "cyclic Markdown continuation maps to partial content")
    } catch { expect(false, "cyclic Markdown continuation returned the wrong error") }

    let tooManyIDs = (0...100).map {
        String(format: "00000000-0000-0000-0000-%012x", $0)
    }
    let oversizedTransport = QueueTransport([
        QueueTransport.json(200, row),
        QueueTransport.json(200, [
            "markdown": "Too many continuations", "truncated": true,
            "unknown_block_ids": tooManyIDs,
        ]),
    ])
    do {
        _ = try await NotionReflectionService(
            client: NotionHTTPClient(tokenStore: SpyTokenStore("secret"),
                                     transport: oversizedTransport),
            cache: NotionReflectionCache(fileURL: temporaryURL()))
            .sync(target: NotionTarget(kind: .page, id: pageA), trigger: .manual)
        expect(false, "oversized Markdown continuation sets must fail closed")
    } catch let error as NotionBackendError {
        expect(error == .partialContent, "continuation bounds map to partial content")
    } catch { expect(false, "oversized Markdown continuation returned the wrong error") }
}

private func testWriteback() async {
    let preview = NotionWritebackPreviewBuilder.build(
        draftID: "draft-1", destination: .appendToPage(pageID: pageA),
        dateRange: "2026-07-27 → 2026-08-02", source: "Mimo activity + selected Notion reflections",
        evidenceIDs: ["E2", "E1"], synthesisMarkdown: "A careful synthesis.")
    let same = NotionWritebackPreviewBuilder.build(
        draftID: "draft-1", destination: .appendToPage(pageID: pageA),
        dateRange: "2026-07-27 → 2026-08-02", source: "Mimo activity + selected Notion reflections",
        evidenceIDs: ["E1", "E2"], synthesisMarkdown: "A careful synthesis.")
    expect(preview.idempotencyKey == same.idempotencyKey, "idempotency key is stable and evidence-order independent")
    expect(preview.markdown.contains("Date range") && preview.markdown.contains("Evidence") &&
           preview.markdown.contains("Mimo Synthesis"), "preview exposes scope and evidence")

    let expectedMarker = writebackMarker(for: preview.idempotencyKey)

    let transport = QueueTransport([
        QueueTransport.json(200, ["markdown": "Existing", "truncated": false,
                                      "unknown_block_ids": []]),
        QueueTransport.json(200, ["markdown": "Existing\n\n\(expectedMarker)",
                                  "truncated": false, "unknown_block_ids": []]),
    ])
    let ledgerURL = temporaryURL("ledger-\(UUID().uuidString)")
    let executor = NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: transport), ledgerURL: ledgerURL)
    let unconfirmed = await executor.execute(preview, confirmed: false)
    if case .confirmationRequired(let preserved) = unconfirmed { expect(preserved == preview, "preview preserved") }
    else { expect(false, "writeback must require explicit confirmation") }
    expect(transport.requests.isEmpty, "unconfirmed preview performs no network write")
    let written = await executor.execute(preview, confirmed: true)
    if case .written = written {} else { expect(false, "confirmed write succeeds") }
    let repeated = await executor.execute(preview, confirmed: true)
    if case .alreadyWritten = repeated {} else { expect(false, "duplicate key is idempotent") }
    expect(transport.requests.count == 2 && transport.requests[0].httpMethod == "GET"
           && transport.requests[1].httpMethod == "PATCH",
           "append preflights its durable marker then writes exactly once")
    let restartedTransport = QueueTransport([])
    let restarted = NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: restartedTransport), ledgerURL: ledgerURL)
    let afterRestart = await restarted.execute(preview, confirmed: true)
    if case .alreadyWritten = afterRestart {} else { expect(false, "idempotency survives relaunch") }
    expect(restartedTransport.requests.isEmpty, "persisted idempotency key prevents a second remote write")
    let appendBody = transport.requests[1].httpBody.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let appendType = appendBody?["type"] as? String
    let insert = appendBody?["insert_content"] as? [String: Any]
    let positionType = (insert?["position"] as? [String: Any])?["type"] as? String
    let appendedContent = insert?["content"] as? String ?? ""
    expect(appendType == "insert_content" && positionType == "end"
           && appendedContent.contains("A careful synthesis.")
           && appendedContent.contains("Mimo writeback ID: `mimo-writeback-"),
           "append uses the official nested insert_content body with a durable marker")
    expect(appendBody?["markdown"] == nil && appendBody?["position"] == nil,
           "legacy top-level markdown and position fields are never sent")

    let marker = appendedContent.split(separator: "\n")
        .map(String.init).first { $0.contains("Mimo writeback ID: `mimo-writeback-") }!
    let remoteTransport = QueueTransport([QueueTransport.json(200, [
        "markdown": "Existing\n\n\(marker)", "truncated": false,
        "unknown_block_ids": [],
    ])])
    let remoteExecutor = NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: remoteTransport))
    let remoteRepeat = await remoteExecutor.execute(preview, confirmed: true)
    if case .alreadyWritten = remoteRepeat {} else {
        expect(false, "remote marker protects a retry even without the local ledger")
    }
    expect(remoteTransport.requests.count == 1
           && remoteTransport.requests[0].httpMethod == "GET",
           "remote idempotency marker prevents another PATCH")

    let hiddenMarkerTransport = QueueTransport([
        QueueTransport.json(200, [
            "markdown": "Existing\n\n\(unknownTag(pageB))", "truncated": true,
            "unknown_block_ids": [pageB],
        ]),
        QueueTransport.json(404, [:]),
    ])
    let hiddenMarkerOutcome = await NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: hiddenMarkerTransport))
        .execute(preview, confirmed: true)
    if case .failed(_, let error) = hiddenMarkerOutcome {
        expect(error == .partialContent,
               "inaccessible marker continuation fails closed as ambiguous")
    } else {
        expect(false, "inaccessible marker continuation must never permit an append")
    }
    expect(hiddenMarkerTransport.requests.count == 2
           && hiddenMarkerTransport.requests.allSatisfy { $0.httpMethod == "GET" },
           "permission-hidden continuation never reaches PATCH")

    let concurrentTransport = QueueTransport([
        QueueTransport.json(200, ["markdown": "Existing", "truncated": false,
                                      "unknown_block_ids": []]),
        QueueTransport.json(200, ["markdown": "Existing\n\n\(expectedMarker)",
                                  "truncated": false, "unknown_block_ids": []]),
    ], delayNanoseconds: 50_000_000)
    let concurrentExecutor = NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: concurrentTransport))
    let firstWrite = Task { await concurrentExecutor.execute(preview, confirmed: true) }
    try? await Task.sleep(nanoseconds: 5_000_000)
    let duplicateWhileRunning = await concurrentExecutor.execute(preview, confirmed: true)
    if case .inProgress = duplicateWhileRunning {} else {
        expect(false, "a second Confirm is rejected while the first request is in flight")
    }
    if case .written = await firstWrite.value {} else {
        expect(false, "the first concurrent write still completes")
    }
    expect(concurrentTransport.requests.count == 2,
           "concurrent Confirm cannot emit a duplicate PATCH")

    let truncatedTransport = QueueTransport([
        QueueTransport.json(200, ["markdown": "Existing", "truncated": false,
                                  "unknown_block_ids": []]),
        QueueTransport.json(200, ["markdown": "Existing\n\n\(unknownTag(pageB))",
                                  "truncated": true, "unknown_block_ids": [pageB]]),
        QueueTransport.json(200, ["markdown": expectedMarker, "truncated": false,
                                  "unknown_block_ids": []]),
    ])
    let truncatedOutcome = await NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: truncatedTransport))
        .execute(preview, confirmed: true)
    if case .written = truncatedOutcome {} else {
        expect(false, "truncated update response verifies its continuation marker")
    }
    expect(truncatedTransport.requests.count == 3
           && truncatedTransport.requests[2].url?.path == "/v1/pages/\(pageB)/markdown",
           "successful large-page writeback follows unknown-block continuation before persisting")

    let failingPreview = NotionWritebackPreviewBuilder.build(
        draftID: "draft-fail", destination: .appendToPage(pageID: pageA),
        dateRange: "week", source: "Mimo", evidenceIDs: ["E9"], synthesisMarkdown: "Keep me")
    let failing = NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: QueueTransport([.failure])))
    let outcome = await failing.execute(failingPreview, confirmed: true)
    if case .failed(let preserved, let error) = outcome {
        expect(preserved == failingPreview && error == .network, "failed write preserves complete draft")
    } else { expect(false, "network failure returns preserved draft") }

    let createPreview = NotionWritebackPreviewBuilder.build(
        draftID: "draft-create",
        destination: .createPage(parentPageID: pageA, title: "Weekly Reflection"),
        dateRange: "week", source: "Mimo", evidenceIDs: ["E9"],
        synthesisMarkdown: "Keep me")
    let createTransport = QueueTransport([])
    let createOutcome = await NotionWritebackExecutor(client: NotionHTTPClient(
        tokenStore: SpyTokenStore("secret"), transport: createTransport))
        .execute(createPreview, confirmed: true)
    if case .failed(_, let error) = createOutcome {
        expect(error == .unsupported, "unsafe child-page creation fails closed in the MVP")
    } else { expect(false, "child-page creation must not bypass append idempotency") }
    expect(createTransport.requests.isEmpty, "unsupported child-page creation sends no request")

    let rangeStart = Calendar.current.startOfDay(
        for: Date(timeIntervalSince1970: 1_754_006_400))
    let dateRange = ReflectionDateRange(
        start: rangeStart,
        end: Calendar.current.date(byAdding: .day, value: 1, to: rangeStart)!)
    let coreDraft = SynthesisDraft(id: "core-draft", dateRange: dateRange,
        title: "Reflection", markdown: "Body", evidenceIDs: ["E1"],
        target: .appendPage, targetPageID: pageA, idempotencyKey: "core-key")
    let adapted = try! NotionWritebackPreviewBuilder.build(draft: coreDraft, source: "Mimo")
    expect(adapted.idempotencyKey != "core-key" && adapted.destination == .appendToPage(pageID: pageA),
           "final preview recomputes its key from the confirmed destination and content")
    var changedTarget = coreDraft
    changedTarget.targetPageID = pageB
    var changedContent = coreDraft
    changedContent.markdown += "\n\nA newly marked passage."
    let targetPreview = try! NotionWritebackPreviewBuilder.build(draft: changedTarget, source: "Mimo")
    let contentPreview = try! NotionWritebackPreviewBuilder.build(draft: changedContent, source: "Mimo")
    let sameAdapted = try! NotionWritebackPreviewBuilder.build(draft: coreDraft, source: "Mimo")
    expect(targetPreview.idempotencyKey != adapted.idempotencyKey
           && contentPreview.idempotencyKey != adapted.idempotencyKey
           && sameAdapted.idempotencyKey == adapted.idempotencyKey,
           "target or final marks change the key while an identical retry remains stable")
    let dates = adapted.dateRange.components(separatedBy: " → ")
    expect(dates.count == 2 && dates[0] == dates[1],
           "exclusive range end is rendered as the inclusive final day")
}

@main
struct NotionReflectionTests {
    static func main() async throws {
        testTargetParsing()
        try testMarkdownAndBlocks()
        await testHTTPFailures()
        try await testPaginationIncrementalCacheAndTokenIsolation()
        try await testDatabaseResolvesCurrentDataSources()
        await testIncompletePaginationFailsClosed()
        try await testFallbackRecursion()
        await testWriteback()
        print("notion reflection tests passed")
    }
}
