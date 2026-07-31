// sources: evals/provider_telemetry.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func evidence(role: DIYProviderTelemetryRole = .candidate)
    -> DIYProviderTelemetryEvidence {
    let batches = [("gaze", 3), ("sleep", 2), ("tennis", 3), ("wall", 2)]
    return DIYProviderTelemetryEvidence(
        schemaVersion: 1, dataset: "mimo-diy-v3", role: role,
        cohortID: "candidate-001", runtimeCommit: String(repeating: "a", count: 40),
        contractFingerprint: String(repeating: "b", count: 64),
        inputFingerprint: String(repeating: "c", count: 64),
        quality: "medium", packCount: 1, createdAt: "t0", updatedAt: "t1",
        calls: batches.flatMap { action, count in
            (0..<count).map {
                DIYProviderTelemetryCall(
                    actionID: action, batchIndex: $0,
                    durationSeconds: Double(50 + $0), outcome: "success",
                    estimatedCostUSD: 0.045, outputFilename: "\(action)-\($0).png",
                    usage: nil, error: nil)
            }
        },
        actions: batches.map {
            DIYProviderTelemetryAction(
                actionID: $0.0, passed: true,
                stripFilename: "\($0.0)-strip.png", error: nil)
        })
}

@main
struct ProviderTelemetryTests {
    static func main() throws {
        let valid = evidence()
        let summary = try valid.validated(
            expectedRole: .candidate, expectedDataset: "mimo-diy-v3")
        expect(summary.sampleCount == 10, "one default pack must contain ten calls")
        expect(abs(summary.unitCostUSD - 0.45) < 0.0001,
               "unit cost should be the full default-pack cost")
        expect(summary.callSuccessRate == 1 && summary.actionSuccessRate == 1,
               "all-success evidence should preserve call and action success")

        var missing = valid
        missing.calls.removeLast()
        expect((try? missing.validated(
            expectedRole: .candidate, expectedDataset: "mimo-diy-v3")) == nil,
               "partial cohorts must not unlock a latency gate")

        var dirty = valid
        dirty = DIYProviderTelemetryEvidence(
            schemaVersion: dirty.schemaVersion, dataset: dirty.dataset,
            role: dirty.role, cohortID: dirty.cohortID,
            runtimeCommit: dirty.runtimeCommit + "-dirty",
            contractFingerprint: dirty.contractFingerprint,
            inputFingerprint: dirty.inputFingerprint, quality: dirty.quality,
            packCount: dirty.packCount, createdAt: dirty.createdAt,
            updatedAt: dirty.updatedAt, calls: dirty.calls, actions: dirty.actions)
        expect((try? dirty.validated(
            expectedRole: .candidate, expectedDataset: "mimo-diy-v3")) == nil,
               "dirty runtime evidence must not enter rollout")

        var failed = valid
        failed.calls[0] = DIYProviderTelemetryCall(
            actionID: "gaze", batchIndex: 0, durationSeconds: 80,
            outcome: "failed", estimatedCostUSD: 0.045,
            outputFilename: nil, usage: nil, error: "provider")
        let failedSummary = try failed.validated(
            expectedRole: .candidate, expectedDataset: "mimo-diy-v3")
        expect(failedSummary.callSuccessRate == 0.9,
               "spent provider failures must remain visible to hard gates")

        print("provider telemetry tests passed")
    }
}
