// sources: evals/sleep_safe_zone_telemetry.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func evidence() -> DIYSleepSafeZoneEvidence {
    DIYSleepSafeZoneEvidence(
        schemaVersion: 1,
        dataset: "mimo-sleep-safe-zone-v1",
        actionID: "sleep",
        contractRevision: 3,
        runtimeCommit: String(repeating: "a", count: 40),
        contractFingerprint: String(repeating: "b", count: 64),
        inputFingerprint: String(repeating: "c", count: 64),
        quality: "medium",
        packCount: 12,
        baselineEvidenceSHA256: DIYSleepSafeZoneEvidence.baselineEvidenceSHA256,
        historicalMixedFailures: 1,
        historicalMixedCount: 12,
        historicalSleepFailures: 1,
        historicalSleepCount: 3,
        createdAt: "t0",
        updatedAt: "t1",
        calls: (0..<12).flatMap { pack in
            (0..<2).map { batch in
                DIYSleepSafeZoneCall(
                    packIndex: pack,
                    batchIndex: batch,
                    durationSeconds: 50,
                    outcome: "success",
                    estimatedCostUSD: 0.045,
                    outputFilename: String(
                        format: "pack-%02d/sleep-batch-%02d.png",
                        pack + 1, batch + 1),
                    usage: nil,
                    error: nil)
            }
        },
        results: (0..<12).map { pack in
            DIYSleepSafeZoneResult(
                packIndex: pack,
                passed: true,
                stripFilename: String(
                    format: "pack-%02d/sleep-strip.png", pack + 1),
                error: nil)
        })
}

@main
struct SleepSafeZoneTelemetryTests {
    static func main() throws {
        let valid = evidence()
        let summary = try valid.validated()
        expect(summary.sampleCount == 12 && summary.callCount == 24,
               "the preregistered cohort is exactly twelve two-call sleep packs")
        expect(summary.failedPackCount == 0 && summary.passesTarget,
               "0/12 sleep QA failures passes the targeted gate")
        expect(abs(summary.estimatedCostUSD - 1.08) < 0.0001,
               "medium target cost accounts for all twenty-four calls")

        var failed = valid
        failed.results[3] = DIYSleepSafeZoneResult(
            packIndex: 3,
            passed: false,
            stripFilename: nil,
            error: "cell 2's subject is cut off at its right edge")
        let failedSummary = try failed.validated()
        expect(failedSummary.failedPackCount == 1 && !failedSummary.passesTarget,
               "one clipped result blocks the zero-failure hypothesis")

        var partial = valid
        partial.calls.removeLast()
        expect((try? partial.validated()) == nil,
               "a partial paid cohort cannot pass")

        var duplicate = valid
        duplicate.results[11] = duplicate.results[10]
        expect((try? duplicate.validated()) == nil,
               "every pack needs one distinct QA result")

        var wrongContract = valid
        wrongContract = DIYSleepSafeZoneEvidence(
            schemaVersion: wrongContract.schemaVersion,
            dataset: wrongContract.dataset,
            actionID: wrongContract.actionID,
            contractRevision: 2,
            runtimeCommit: wrongContract.runtimeCommit,
            contractFingerprint: wrongContract.contractFingerprint,
            inputFingerprint: wrongContract.inputFingerprint,
            quality: wrongContract.quality,
            packCount: wrongContract.packCount,
            baselineEvidenceSHA256: wrongContract.baselineEvidenceSHA256,
            historicalMixedFailures: wrongContract.historicalMixedFailures,
            historicalMixedCount: wrongContract.historicalMixedCount,
            historicalSleepFailures: wrongContract.historicalSleepFailures,
            historicalSleepCount: wrongContract.historicalSleepCount,
            createdAt: wrongContract.createdAt,
            updatedAt: wrongContract.updatedAt,
            calls: wrongContract.calls,
            results: wrongContract.results)
        expect((try? wrongContract.validated()) == nil,
               "rev-2 evidence cannot validate the rev-3 safe-zone mechanism")

        print("sleep safe-zone telemetry tests passed")
    }
}
