// Mimo — activity-log naming and retention primitives.
//
// Split out of main.swift so the retention and erase rules are reachable from
// tests: main.swift is top-level code and cannot be linked beside another
// @main, so anything that lived there was permanently untestable. These two
// rules destroyed real user data, so they belong somewhere a test can see.

import Foundation

/// Every log filename, export filename, and retention comparison goes through
/// this one formatter.
///
/// A bare `DateFormatter` follows the user's locale and calendar. Under a
/// non-Gregorian calendar — Buddhist, Japanese-era, Persian, all selectable in
/// System Settings — "2026-07-18" parses against *that* calendar. Under
/// Buddhist that lands ~543 years in the past, so the retention sweep matched
/// every file and deleted the entire activity history; under Japanese-era it
/// never matched and nothing was ever pruned.
let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func logDayStamp(_ date: Date = Date()) -> String { logDateFormatter.string(from: date) }

/// Lines of `text` that survive "forget everything after `ts`" (ms epoch).
///
/// Fails **open**: a line this cannot parse is kept. The original returned
/// false for anything unparseable, so a record truncated by a crash — or
/// written by a future schema without `t1` — was silently destroyed by an
/// unrelated "forget the last hour". A filter whose job is preserving data
/// must never treat "I don't understand this" as "delete it".
func retainedLogLines(in text: String, erasingAfter ts: Double) -> [String] {
    text.split(separator: "\n").map(String.init).filter { line in
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        guard let t1 = object["t1"] as? Double else { return true }
        return t1 <= ts
    }
}

/// Every day whose log file may hold entries after `ts`.
///
/// "Forget the last hour" at 00:30 puts the cutoff in yesterday's file. Only
/// today's was ever opened, so half the window survived on disk while the UI
/// reported success.
func logDaysToErase(after ts: Double, now: Date = Date(),
                    calendar: Calendar = .current) -> [Date] {
    let from = Date(timeIntervalSince1970: ts / 1000)
    let today = calendar.startOfDay(for: now)
    var day = calendar.startOfDay(for: min(from, now))
    var days: [Date] = []
    while day <= today {
        days.append(day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
    }
    return days
}

/// Native generation fence for WebKit activity-log messages.
///
/// `WKScriptMessage` delivery is asynchronous. A checkpoint posted before the
/// user chooses Forget can therefore reach native code after the JSONL rewrite
/// and recreate the entry that was just erased. Starting an erase advances the
/// generation immediately and blocks every append until the rewrite finishes.
/// The overlay receives that new generation only after the rewrite, starts a
/// fresh segment, and all already-queued messages remain permanently stale.
struct ActivityLogWriteFence {
    private(set) var generation: Int
    private(set) var isErasing = false

    init(generation: Int = 0) {
        self.generation = max(0, generation)
    }

    @discardableResult
    mutating func beginErase() -> Int {
        // A user cannot approach Int.max erases in one process lifetime. Avoid
        // wrapping because a wrapped generation could match a very old payload.
        precondition(generation < Int.max, "activity log generation exhausted")
        generation += 1
        isErasing = true
        return generation
    }

    mutating func finishErase(generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        isErasing = false
    }

    func accepts(generation candidate: Int?) -> Bool {
        !isErasing && candidate == generation
    }
}
