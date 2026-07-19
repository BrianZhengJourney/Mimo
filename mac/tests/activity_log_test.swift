// sources: activity_log.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ActivityLogTests {
    static func main() {
        // ── the retention formatter must not follow the user's calendar ──
        // Under a Buddhist or Japanese-era calendar a bare DateFormatter
        // reads "2026-07-18" against that calendar; the retention sweep then
        // deleted every log file, or none of them, forever.
        let stamp = "2026-07-18"
        guard let parsed = logDateFormatter.date(from: stamp) else {
            FileHandle.standardError.write(Data("FAIL: could not parse \(stamp)\n".utf8))
            exit(1)
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = logDateFormatter.timeZone
        expect(gregorian.component(.year, from: parsed) == 2026,
               "a log stamp must parse as a Gregorian year regardless of user locale")
        expect(logDateFormatter.string(from: parsed) == stamp,
               "formatting round-trips the filename stamp")

        for identifier in ["th_TH", "ja_JP@calendar=japanese", "fa_IR", "en_US"] {
            let scoped = DateFormatter()
            scoped.locale = Locale(identifier: "en_US_POSIX")
            scoped.calendar = Calendar(identifier: .gregorian)
            scoped.dateFormat = "yyyy-MM-dd"
            expect(scoped.date(from: stamp) == parsed,
                   "the pinned formatter is stable under \(identifier)")
        }

        // ── the erase filter must fail open ──
        let text = [
            "{\"t1\":1000,\"app\":\"keep\"}",
            "{\"t1\":9000,\"app\":\"drop\"}",
            "{\"t1\":900",                      // truncated by a crash
            "not json at all",
            "{\"app\":\"future schema, no t1\"}",
        ].joined(separator: "\n")

        let kept = retainedLogLines(in: text, erasingAfter: 5000)
        expect(kept.contains("{\"t1\":1000,\"app\":\"keep\"}"),
               "entries before the cutoff survive")
        expect(!kept.contains("{\"t1\":9000,\"app\":\"drop\"}"),
               "entries after the cutoff are erased")
        expect(kept.contains("{\"t1\":900"),
               "a line truncated by a crash must not be destroyed by an unrelated erase")
        expect(kept.contains("not json at all"),
               "an unparseable line must not be destroyed by an unrelated erase")
        expect(kept.contains("{\"app\":\"future schema, no t1\"}"),
               "a record from a future schema must not be destroyed by an unrelated erase")
        expect(kept.count == 4, "exactly one entry is erased")

        // ── the erase must span every day the window touches ──
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnightThirty = Date(timeIntervalSince1970: 1_752_800_000)
        let startOfDay = calendar.startOfDay(for: midnightThirty)
        let halfHourIn = startOfDay.addingTimeInterval(30 * 60)
        let anHourBefore = halfHourIn.timeIntervalSince1970 * 1000 - 3_600_000

        let days = logDaysToErase(after: anHourBefore, now: halfHourIn, calendar: calendar)
        expect(days.count == 2,
               "forgetting the last hour at 00:30 must reach yesterday's file too, not just today's")
        expect(days.last == startOfDay, "today is always included")

        let sameDay = logDaysToErase(
            after: startOfDay.addingTimeInterval(6 * 3600).timeIntervalSince1970 * 1000,
            now: startOfDay.addingTimeInterval(7 * 3600), calendar: calendar)
        expect(sameDay.count == 1, "a window inside one day touches one file")

        let future = logDaysToErase(
            after: halfHourIn.addingTimeInterval(86_400).timeIntervalSince1970 * 1000,
            now: halfHourIn, calendar: calendar)
        expect(future.count == 1,
               "a cutoff in the future still sweeps today rather than looping forever")

        print("activity log tests passed")
    }
}
