// Mimo Today Journal — optional, localhost-only ActivityWatch adapter.
//
// The adapter reads ActivityWatch buckets only when the user enables it. Raw
// watcher shapes are normalized into Mimo's canonical ActivityEvent contract;
// the journal and graph never depend on watcher-specific fields.

import Foundation

enum ActivityWatchAdapterError: Error, Equatable {
    case unreachable
    case invalidResponse
    case responseTooLarge
    case malformed
}

enum ActivityWatchBucketKind: String, Equatable {
    case window
    case web
    case afk
}

struct ActivityWatchBucketDescriptor: Equatable {
    var id: String
    var type: String
    var client: String
    var hostname: String
    var lastUpdated: Date?

    var kind: ActivityWatchBucketKind? {
        let value = "\(id) \(type) \(client)".lowercased()
        if type.lowercased() == "currentwindow" || value.contains("watcher-window") {
            return .window
        }
        if type.lowercased().contains("web.tab") || value.contains("watcher-web") {
            return .web
        }
        if type.lowercased() == "afkstatus" || value.contains("watcher-afk") {
            return .afk
        }
        return nil
    }
}

struct ActivityWatchBucketPayload {
    var descriptor: ActivityWatchBucketDescriptor
    var events: [[String: Any]]
}

struct ActivityWatchFetchResult {
    var events: [ActivityEvent]
    var failedBucketIDs: [String]
    var bucketCount: Int
}

final class ActivityWatchClient {
    static let endpoint = URL(string: "http://127.0.0.1:5600/api/0/")!
    static let maximumResponseBytes = 32 * 1024 * 1024

    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession? = nil, baseURL: URL = ActivityWatchClient.endpoint) {
        precondition(Self.isLoopback(baseURL), "ActivityWatch must stay on loopback")
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2.5
            configuration.timeoutIntervalForResource = 8
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetch(range: ReflectionDateRange,
               completion: @escaping (Result<ActivityWatchFetchResult,
                                      ActivityWatchAdapterError>) -> Void) {
        let bucketsURL = baseURL.appendingPathComponent("buckets", isDirectory: false)
        request(bucketsURL) { [weak self] result in
            guard let self else { return completion(.failure(.unreachable)) }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let data):
                guard let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else {
                    return completion(.failure(.malformed))
                }
                let descriptors = self.descriptors(from: object)
                let selected = self.selectedBuckets(descriptors)
                guard !selected.isEmpty else {
                    return completion(.success(.init(
                        events: [], failedBucketIDs: [], bucketCount: 0)))
                }
                self.fetchEvents(for: selected, range: range, completion: completion)
            }
        }
    }

    private func fetchEvents(
        for buckets: [ActivityWatchBucketDescriptor], range: ReflectionDateRange,
        completion: @escaping (Result<ActivityWatchFetchResult,
                               ActivityWatchAdapterError>) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var payloads: [ActivityWatchBucketPayload] = []
        var failed: [String] = []
        for bucket in buckets {
            guard let url = eventsURL(bucketID: bucket.id, range: range) else {
                failed.append(bucket.id)
                continue
            }
            group.enter()
            request(url) { result in
                lock.lock(); defer { lock.unlock(); group.leave() }
                switch result {
                case .failure: failed.append(bucket.id)
                case .success(let data):
                    guard let rows = try? JSONSerialization.jsonObject(with: data)
                            as? [[String: Any]] else {
                        failed.append(bucket.id)
                        return
                    }
                    payloads.append(.init(descriptor: bucket,
                                          events: Array(rows.prefix(50_000))))
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            if payloads.isEmpty, !failed.isEmpty {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(.init(
                events: ActivityWatchCanonicalizer.events(
                    from: payloads, range: range),
                failedBucketIDs: failed.sorted(), bucketCount: payloads.count)))
        }
    }

    private func request(_ url: URL,
                         completion: @escaping (Result<Data,
                                                ActivityWatchAdapterError>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if error != nil { return completion(.failure(.unreachable)) }
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode, let data else {
                return completion(.failure(.invalidResponse))
            }
            guard data.count <= Self.maximumResponseBytes else {
                return completion(.failure(.responseTooLarge))
            }
            completion(.success(data))
        }.resume()
    }

    private func descriptors(from object: [String: Any]) -> [ActivityWatchBucketDescriptor] {
        object.compactMap { id, raw -> ActivityWatchBucketDescriptor? in
            guard id.utf8.count <= 300, let row = raw as? [String: Any] else { return nil }
            return .init(
                id: id, type: row["type"] as? String ?? "",
                client: row["client"] as? String ?? "",
                hostname: row["hostname"] as? String ?? "",
                lastUpdated: (row["last_updated"] as? String).flatMap(Self.date))
        }
    }

    private func selectedBuckets(_ input: [ActivityWatchBucketDescriptor])
        -> [ActivityWatchBucketDescriptor] {
        let sorted = input.filter { $0.kind != nil }.sorted {
            ($0.lastUpdated ?? .distantPast) > ($1.lastUpdated ?? .distantPast)
        }
        let limits: [ActivityWatchBucketKind: Int] = [.window: 4, .web: 4, .afk: 2]
        var counts: [ActivityWatchBucketKind: Int] = [:]
        return sorted.filter { bucket in
            guard let kind = bucket.kind,
                  counts[kind, default: 0] < limits[kind, default: 0] else { return false }
            counts[kind, default: 0] += 1
            return true
        }
    }

    private func eventsURL(bucketID: String, range: ReflectionDateRange) -> URL? {
        let url = baseURL.appendingPathComponent("buckets", isDirectory: true)
            .appendingPathComponent(bucketID, isDirectory: true)
            .appendingPathComponent("events", isDirectory: false)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            .init(name: "start", value: Self.timestamp(range.start)),
            .init(name: "end", value: Self.timestamp(range.end)),
            .init(name: "limit", value: "-1"),
        ]
        return components.url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    fileprivate static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

enum ActivityWatchCanonicalizer {
    private struct RawEvent {
        var id: String
        var bucket: ActivityWatchBucketDescriptor
        var startMS: Double
        var endMS: Double
        var data: [String: Any]
    }

    static func events(from payloads: [ActivityWatchBucketPayload],
                       range: ReflectionDateRange) -> [ActivityEvent] {
        var windows: [RawEvent] = [], web: [RawEvent] = [], afk: [RawEvent] = []
        for payload in payloads {
            guard let kind = payload.descriptor.kind else { continue }
            for (index, row) in payload.events.enumerated() {
                guard let timestamp = row["timestamp"] as? String,
                      let date = ActivityWatchClient.date(timestamp),
                      let duration = number(row["duration"]), duration > 0,
                      duration <= 86_400,
                      let data = row["data"] as? [String: Any] else { continue }
                let rawStart = date.timeIntervalSince1970 * 1_000
                let start = max(rawStart, range.start.timeIntervalSince1970 * 1_000)
                let end = min(rawStart + duration * 1_000,
                              range.end.timeIntervalSince1970 * 1_000)
                guard end - start >= 500 else { continue }
                let rawID = (row["id"] as? NSNumber)?.stringValue
                    ?? row["id"] as? String ?? String(index)
                let event = RawEvent(
                    id: "\(payload.descriptor.id):\(rawID):\(timestamp)",
                    bucket: payload.descriptor, startMS: start, endMS: end,
                    data: data)
                switch kind {
                case .window: windows.append(event)
                case .web: web.append(event)
                case .afk: afk.append(event)
                }
            }
        }
        let afkIntervals = mergedIntervals(afk.compactMap { event in
            let status = (event.data["status"] as? String ?? "").lowercased()
            return status == "afk" ? (event.startMS, event.endMS) : nil
        })
        let source = windows.isEmpty ? web : windows
        var output: [ActivityEvent] = []
        for raw in source.sorted(by: { $0.startMS < $1.startMS }) {
            let baseApp = (raw.data["app"] as? String)?.trimmedAW
                ?? inferredBrowserName(raw.bucket)
            guard let baseApp else { continue }
            let matchingWeb = raw.bucket.kind == .window && isBrowser(baseApp)
                ? web.max(by: { overlap($0, raw) < overlap($1, raw) }) : nil
            let webIsRelevant = matchingWeb.map {
                overlap($0, raw) / max(1, min($0.endMS - $0.startMS,
                                              raw.endMS - raw.startMS)) >= 0.35
            } ?? false
            let detail = webIsRelevant ? matchingWeb!.data : raw.data
            let title = (detail["title"] as? String)?.trimmedAW
                ?? (raw.data["title"] as? String)?.trimmedAW
            let fullURL = safeURL(detail["url"] as? String)
            let domain = fullURL.flatMap { URL(string: $0)?.host?.lowercased() }?
                .replacingOccurrences(of: "^www\\.", with: "",
                                      options: .regularExpression)
            for (sliceIndex, slice) in activeSlices(
                start: raw.startMS, end: raw.endMS, excluding: afkIntervals).enumerated() {
                let fingerprint = "\(raw.id)|\(sliceIndex)|\(slice.0)|\(slice.1)|\(baseApp)|\(title ?? "")|\(fullURL ?? "")"
                output.append(ActivityEvent(
                    id: stableAWID(fingerprint), startedAtMS: slice.0,
                    endedAtMS: slice.1, app: baseApp, title: title,
                    fullURL: fullURL, domain: domain, category: rawCategory(domain, fullURL),
                    canonicalLabel: nil, source: "activitywatch", order: output.count))
            }
        }
        ActivityEventSequencer.sequence(&output)
        return output
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func inferredBrowserName(_ bucket: ActivityWatchBucketDescriptor) -> String? {
        let value = "\(bucket.id) \(bucket.client)".lowercased()
        for pair in [("chrome", "Google Chrome"), ("firefox", "Firefox"),
                     ("safari", "Safari"), ("edge", "Microsoft Edge"),
                     ("brave", "Brave"), ("arc", "Arc")] where value.contains(pair.0) {
            return pair.1
        }
        return bucket.kind == .web ? "Browser" : nil
    }

    private static func isBrowser(_ app: String) -> Bool {
        let value = app.lowercased()
        return ["chrome", "safari", "arc", "firefox", "edge", "brave", "opera"]
            .contains(where: value.contains)
    }

    private static func safeURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmedAW, raw.utf8.count <= 8_192,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host != nil else { return nil }
        return components.url?.absoluteString
    }

    private static func rawCategory(_ domain: String?, _ url: String?) -> String {
        let value = domain ?? "", lowerURL = url?.lowercased() ?? ""
        let learning = ["arxiv.org", "openreview.net", "acm.org", "ieee.org",
                        "wikipedia.org", "medium.com", "substack.com"]
        return learning.contains(where: { value == $0 || value.hasSuffix("." + $0) })
            || lowerURL.contains(".pdf") ? "paper" : "neutral"
    }

    private static func overlap(_ lhs: RawEvent, _ rhs: RawEvent) -> Double {
        max(0, min(lhs.endMS, rhs.endMS) - max(lhs.startMS, rhs.startMS))
    }

    private static func mergedIntervals(_ input: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = input.sorted { $0.0 < $1.0 }
        var output: [(Double, Double)] = []
        for interval in sorted {
            guard let last = output.last, interval.0 <= last.1 else {
                output.append(interval); continue
            }
            output[output.count - 1].1 = max(last.1, interval.1)
        }
        return output
    }

    private static func activeSlices(start: Double, end: Double,
                                     excluding intervals: [(Double, Double)])
        -> [(Double, Double)] {
        var slices = [(start, end)]
        for interval in intervals where interval.1 > start && interval.0 < end {
            slices = slices.flatMap { slice -> [(Double, Double)] in
                guard interval.1 > slice.0 && interval.0 < slice.1 else { return [slice] }
                var values: [(Double, Double)] = []
                if interval.0 - slice.0 >= 500 { values.append((slice.0, interval.0)) }
                if slice.1 - interval.1 >= 500 { values.append((interval.1, slice.1)) }
                return values
            }
        }
        return slices
    }

    private static func stableAWID(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash ^= UInt64(byte); hash = hash &* 1_099_511_628_211 }
        return "aw-\(String(hash, radix: 16))"
    }
}

enum ActivitySourceMerger {
    static func merge(primary: [ActivityEvent], supplemental: [ActivityEvent])
        -> [ActivityEvent] {
        guard !supplemental.isEmpty else {
            var output = primary; ActivityEventSequencer.sequence(&output); return output
        }
        let coverage = mergedCoverage(supplemental.map { ($0.startedAtMS, $0.endedAtMS) })
        var output = supplemental
        for event in primary {
            for (index, slice) in uncoveredSlices(
                start: event.startedAtMS, end: event.endedAtMS,
                coverage: coverage).enumerated() where slice.1 - slice.0 >= 500 {
                var copy = event
                copy.startedAtMS = slice.0; copy.endedAtMS = slice.1
                if slice.0 != event.startedAtMS || slice.1 != event.endedAtMS {
                    copy.id = "\(event.id)-gap-\(index)-\(Int(slice.0))"
                }
                output.append(copy)
            }
        }
        ActivityEventSequencer.sequence(&output)
        return output
    }

    private static func mergedCoverage(_ input: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = input.sorted { $0.0 < $1.0 }
        var output: [(Double, Double)] = []
        for item in sorted {
            guard let last = output.last, item.0 <= last.1 + 250 else {
                output.append(item); continue
            }
            output[output.count - 1].1 = max(last.1, item.1)
        }
        return output
    }

    private static func uncoveredSlices(start: Double, end: Double,
                                        coverage: [(Double, Double)])
        -> [(Double, Double)] {
        var cursor = start, output: [(Double, Double)] = []
        for item in coverage where item.1 > start && item.0 < end {
            if item.0 > cursor { output.append((cursor, min(end, item.0))) }
            cursor = max(cursor, item.1)
            if cursor >= end { break }
        }
        if cursor < end { output.append((cursor, end)) }
        return output
    }
}

private extension String {
    var trimmedAW: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
