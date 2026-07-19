// sources: generation_ledger.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct GenerationLedgerTests {
    static func main() {
        var ledger = StudioGenerationLedger()
        let now = Date()
        expect(ledger.reserve(requestID: "a", now: now) == .accepted,
               "a fresh paid request should reserve exactly once")
        expect(ledger.reserve(requestID: "a", now: now) == .duplicateActive,
               "a duplicated active bridge event must not create a second paid call")
        expect(ledger.reserve(requestID: "b", now: now) == .anotherRequestActive,
               "parallel paid calls should be rejected by the single-flight studio")
        ledger.finish(requestID: "a")
        expect(ledger.reserve(requestID: "a", now: now) == .requestIDReused,
               "a completed or cancelled provider ID must not be replayed")
        expect(ledger.reserve(requestID: "b", now: now) == .accepted,
               "a fresh ID should work after the prior request finishes")
        ledger.finish(requestID: "b")
        expect(ledger.reserveLocalProcessing(requestID: "a"),
               "explicit local recovery may reuse a previously paid ID")
        expect(!ledger.reserveLocalProcessing(requestID: "a"),
               "local recovery remains single-flight")
        ledger.finish(requestID: "a")
        ledger.prune(before: now.addingTimeInterval(1))
        expect(ledger.usedRequestIDs.isEmpty,
               "old ledger entries should expire without growing forever")

        let old = now.addingTimeInterval(-31 * 60)
        let recent = now.addingTimeInterval(-2 * 60)
        let drafts = ["paid-parent": old, "fresh": recent, "expired": old]
        let retained = retainingStudioDrafts(
            drafts, newerThan: now.addingTimeInterval(-30 * 60),
            pinnedIDs: ["paid-parent"], lastTouchedAt: { $0 })
        expect(Set(retained.keys) == ["paid-parent", "fresh"],
               "an active/recoverable stage must pin its paid parent across the expiry boundary")

        // Each draft is several full-size PNGs. A user iterating in Settings
        // could pile up a dozen inside the 30-minute window, and the prune
        // timer only fires every 5 minutes.
        let manyDrafts = Dictionary(uniqueKeysWithValues: (0..<12).map {
            ("draft-\($0)", now.addingTimeInterval(-Double($0) * 60))
        })
        let capped = retainingStudioDrafts(
            manyDrafts, newerThan: now.addingTimeInterval(-30 * 60),
            pinnedIDs: [], maximumCount: 6, now: now, lastTouchedAt: { $0 })
        expect(capped.count == 6, "in-memory drafts need a hard count cap, not just a time window")
        expect(capped["draft-0"] != nil && capped["draft-5"] != nil,
               "the most recently touched drafts are the ones kept")
        expect(capped["draft-11"] == nil, "the oldest drafts are dropped first")

        // A pin used to exempt a draft from expiry unconditionally, so a leaked
        // activeStageParents entry held its draft for the process lifetime.
        let leaked = ["pinned-forever": now.addingTimeInterval(-10 * 60 * 60)]
        let afterLeak = retainingStudioDrafts(
            leaked, newerThan: now.addingTimeInterval(-30 * 60),
            pinnedIDs: ["pinned-forever"], now: now, lastTouchedAt: { $0 })
        expect(afterLeak.isEmpty,
               "a pin should buy a longer life, not an unlimited one")

        // ...but a pin still has to outlive the ordinary cutoff.
        let stillWorking = ["pinned-recent": now.addingTimeInterval(-45 * 60)]
        let afterPin = retainingStudioDrafts(
            stillWorking, newerThan: now.addingTimeInterval(-30 * 60),
            pinnedIDs: ["pinned-recent"], now: now, lastTouchedAt: { $0 })
        expect(afterPin.count == 1,
               "an active stage must still pin its paid parent past the ordinary cutoff")

        // A dropped completion handler used to leave activeRequestID set with
        // no expiry, refusing every later generation until the app restarted.
        var wedged = StudioGenerationLedger()
        expect(wedged.reserve(requestID: "lost", now: now) == .accepted,
               "the first request reserves")
        expect(wedged.reserve(requestID: "next", now: now.addingTimeInterval(60))
               == .anotherRequestActive,
               "a live request still blocks a parallel one")
        let afterLifetime = now.addingTimeInterval(StudioGenerationLedger.reservationLifetime + 1)
        expect(wedged.reserve(requestID: "next", now: afterLifetime) == .accepted,
               "a reservation outliving the longest request must expire, not wedge the studio")
        expect(wedged.activeRequestID == "next",
               "the expired reservation is replaced by the new one")

        // Local recovery is only meaningful while the request is still recent.
        var stale = StudioGenerationLedger()
        _ = stale.reserve(requestID: "old", now: now)
        stale.finish(requestID: "old")
        expect(!stale.reserveLocalProcessing(requestID: "old",
                                             now: now.addingTimeInterval(3600),
                                             maximumAge: 1800),
               "a request older than the recovery window is not a live candidate")
        expect(stale.reserveLocalProcessing(requestID: "old",
                                            now: now.addingTimeInterval(60),
                                            maximumAge: 1800),
               "a recent request is still recoverable locally")
        print("generation ledger tests passed")
    }
}
