// sources: reflection_core.swift activity_watch.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ActivityWatchTests {
    static func main() throws {
        let start = ISO8601DateFormatter().date(from: "2026-08-07T02:00:00Z")!
        let range = ReflectionDateRange(
            start: start, end: start.addingTimeInterval(20 * 60))
        let window = ActivityWatchBucketDescriptor(
            id: "aw-watcher-window_test", type: "currentwindow",
            client: "aw-watcher-window", hostname: "mac", lastUpdated: nil)
        let web = ActivityWatchBucketDescriptor(
            id: "aw-watcher-web-chrome_test", type: "web.tab.current",
            client: "aw-watcher-web-chrome", hostname: "mac", lastUpdated: nil)
        let afk = ActivityWatchBucketDescriptor(
            id: "aw-watcher-afk_test", type: "afkstatus",
            client: "aw-watcher-afk", hostname: "mac", lastUpdated: nil)
        let payloads = [
            ActivityWatchBucketPayload(descriptor: window, events: [[
                "id": 1, "timestamp": "2026-08-07T02:00:00.000Z", "duration": 600,
                "data": ["app": "Google Chrome", "title": "Google Chrome"],
            ]]),
            ActivityWatchBucketPayload(descriptor: web, events: [[
                "id": 2, "timestamp": "2026-08-07T02:00:00.000Z", "duration": 600,
                "data": ["title": "Activity tracking as sensemaking",
                         "url": "https://arxiv.org/abs/1234"],
            ]]),
            ActivityWatchBucketPayload(descriptor: afk, events: [[
                "id": 3, "timestamp": "2026-08-07T02:04:00.000Z", "duration": 120,
                "data": ["status": "afk"],
            ]]),
        ]
        let events = ActivityWatchCanonicalizer.events(from: payloads, range: range)
        expect(events.count == 2
               && events.reduce(0) { $0 + $1.durationMS } == 8 * 60_000,
               "AFK intervals split foreground heartbeats without counting idle time")
        expect(events.allSatisfy {
            $0.app == "Google Chrome" && $0.source == "activitywatch"
                && $0.title == "Activity tracking as sensemaking"
                && $0.domain == "arxiv.org"
                && $0.category == "paper"
        }, "window and web-tab buckets become one enriched canonical event stream")
        expect(ActivityCategory.classify(events[0]) == .learning,
               "ActivityWatch web evidence uses the same local category contract")

        let primary = [ActivityEvent(
            id: "mimo-1", startedAtMS: start.timeIntervalSince1970 * 1_000,
            endedAtMS: start.addingTimeInterval(20 * 60).timeIntervalSince1970 * 1_000,
            app: "Google Chrome", title: "coarse", category: "neutral", order: 0)]
        let merged = ActivitySourceMerger.merge(primary: primary, supplemental: events)
        expect(merged.filter { $0.source == "mimo" }.count == 2
               && merged.filter { $0.source == "activitywatch" }.count == 2,
               "ActivityWatch coverage replaces only matching time and preserves uncovered Mimo evidence")
        expect(merged.reduce(0) { $0 + $1.durationMS } == 20 * 60_000,
               "combining local sources never double-counts active time")
        expect(merged.map(\.order) == Array(0..<merged.count),
               "the merged stream is deterministically resequenced")

        let webOnly = ActivityWatchCanonicalizer.events(
            from: [payloads[1]], range: range)
        expect(webOnly.count == 1 && webOnly[0].app == "Google Chrome",
               "browser buckets remain useful when the window watcher is unavailable")
        print("activity watch tests passed")
    }
}
