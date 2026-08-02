// sources: starter_action.swift starter_action_job.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    } catch {
        // Expected.
    }
}

private func makeBatchPNG() -> Data {
    let width = 1536, height = 1024
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 128, y: 128, width: 256, height: 700))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

@main
struct StarterActionJobTests {
    static let characterID = "custom:7d8dfd2e-e852-4691-a585-c74803211f0d"
    static let otherCharacterID = "custom:21d6f02c-8f60-44d6-bc70-bcd9000ff0b6"

    static func testEnsureCreatesOneDurableCardPerStarterAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StarterActionJobStore(root: root)
        let first = try store.ensureJobs(characterID: characterID)
        let second = try store.ensureJobs(characterID: characterID)

        expect(first.map(\.actionID) == StarterActionID.allCases,
               "Studio receives starter jobs in product order")
        expect(Set(first.map(\.id)).count == 4, "every accepted action has its own durable job")
        expect(first == second, "ensuring a plan is idempotent")
        expect(first.allSatisfy { $0.state == .planned && $0.attempt == 0 },
               "new cards have not spent or started anything")
        expect(StarterActionJobStore(root: root).jobs(characterID: characterID) == first,
               "cards survive store reconstruction")
    }

    static func testJobMovesThroughPaidAndLocalPhasesIntoReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-transitions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StarterActionJobStore(root: root)
        let gaze = try store.ensureJobs(characterID: characterID)[0]
        let requestID = "a97a0f0d-e5d2-4bbf-989e-9132721d8aa3"
        let queued = try store.queue(jobID: gaze.id, requestID: requestID, quality: "medium")
        expect(queued.state == .queued && queued.attempt == 1,
               "explicit queueing begins one visible attempt")
        expect(queued.estimatedProviderCalls
               == StarterActionCatalog.definition(.gaze).estimatedProviderCalls,
               "the job discloses its complete chained-call estimate")

        for batchIndex in 0..<gaze.estimatedProviderCalls {
            let batchRequestID = UUID().uuidString
            let generating = try store.markGenerating(
                jobID: gaze.id,
                phase: "batch-\(batchIndex + 1)-of-\(gaze.estimatedProviderCalls)",
                completedBatches: batchIndex, usedProviderCalls: batchIndex,
                requestID: batchRequestID)
            expect(generating.state == .generating
                   && generating.completedBatches == batchIndex,
                   "provider progress is durable")
            expect(generating.requestID == batchRequestID.lowercased(),
                   "every provider batch receives its own cancellable idempotency key")
            _ = try store.storeCompletedBatch(
                jobID: gaze.id, batchIndex: batchIndex,
                pngData: makeBatchPNG(), usedProviderCalls: batchIndex + 1,
                providerSeconds: Double(batchIndex + 1) * 12.5)
        }
        let completedGaze = try store.record(jobID: gaze.id)
        expect(completedGaze.usedProviderCalls == gaze.estimatedProviderCalls,
               "every completed paid call remains visible")
        expect(completedGaze.providerCallMetrics?.map(\.durationSeconds)
               == [12.5, 25.0, 37.5],
               "provider latency is checkpointed beside every paid batch")
        expect(completedGaze.providerCallMetrics?.allSatisfy {
            $0.outcome == .success
        } == true, "completed batches persist successful provider outcomes")

        let local = try store.markLocalProcessing(jobID: gaze.id, phase: "registering")
        expect(local.state == .localProcessing, "provider completion becomes local processing")

        let resultID = "b89103ae-3ad8-4fee-b097-e72a980774ca"
        let review = try store.markAwaitingReview(jobID: gaze.id, resultJobID: resultID)
        expect(review.state == .awaitingReview && review.resultJobID == resultID,
               "a generated artifact must wait for explicit review")
        let installed = try store.markInstalled(jobID: gaze.id)
        expect(installed.state == .installed, "manual acceptance completes the card")

        expectThrows("installed jobs cannot silently restart and spend again") {
            _ = try store.queue(jobID: gaze.id, requestID: UUID().uuidString,
                                quality: "medium")
        }
        let reprocessing = try store.beginLocalReprocess(jobID: gaze.id)
        expect(reprocessing.state == .localProcessing
               && reprocessing.usedProviderCalls == gaze.estimatedProviderCalls,
               "an installed result can reuse its retained batches without another paid call")
        expect(reprocessing.resultJobID == nil,
               "the repaired artifact must return through manual review as a new result")
    }

    static func testRestartFailsClosedWithoutRepeatingPaidWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var store: StarterActionJobStore? = StarterActionJobStore(root: root)
        let sleep = try store!.ensureJobs(characterID: characterID)[1]
        _ = try store!.queue(jobID: sleep.id, requestID: UUID().uuidString,
                             quality: "medium")
        _ = try store!.markGenerating(
            jobID: sleep.id, phase: "batch-1-of-\(sleep.estimatedProviderCalls)",
            completedBatches: 0, usedProviderCalls: 0)
        let completed = try store!.storeCompletedBatch(
            jobID: sleep.id, batchIndex: 0,
            pngData: makeBatchPNG(), usedProviderCalls: 1,
            providerSeconds: 18.25)
        expect(completed.completedBatches == 1 && completed.usedProviderCalls == 1,
               "each paid completed batch is durably checkpointed")
        store = nil

        let reopened = StarterActionJobStore(root: root)
        let recovered = reopened.jobs(characterID: characterID)
            .first { $0.actionID == .sleep }!
        expect(recovered.state == .failed && recovered.errorCode == "interrupted",
               "an in-flight restart becomes an honest retryable failure")
        expect(recovered.usedProviderCalls == 1 && recovered.attempt == 1,
               "recovery preserves spend and attempt history")
        let retainedBatch = try reopened.batchData(jobID: sleep.id, batchIndex: 0)
        expect(retainedBatch == makeBatchPNG(),
               "recovery preserves the completed provider artifact")
        expect(recovered.requestID == nil,
               "no stale request ID can resume or duplicate a provider call")
        expect(recovered.canStart,
               "the user can explicitly retry after seeing the interruption")

        let resumed = try reopened.queue(
            jobID: sleep.id, requestID: UUID().uuidString, quality: "medium")
        expect(resumed.completedBatches == 1 && resumed.usedProviderCalls == 1,
               "explicit retry resumes at the first unfinished batch without hidden spend")
    }

    static func testRevisedSleepKeepsPaidLegacyAndCreatesANewCurrentCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-contract-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyID = UUID().uuidString.lowercased()
        let legacyResultID = UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(
            StarterActionJobStore.folderName, isDirectory: true)
            .appendingPathComponent(legacyID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let legacy = StarterActionJobRecord(
            schemaVersion: StarterActionJobRecord.schemaVersion,
            id: legacyID,
            characterID: characterID,
            actionID: .sleep,
            contractRevision: nil,
            state: .awaitingReview,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            attempt: 1,
            maximumAttempts: StarterActionJobRecord.maximumAttempts,
            requestID: nil,
            quality: "medium",
            phase: "awaiting-review",
            completedBatches: 3,
            estimatedProviderCalls: 3,
            usedProviderCalls: 3,
            resultJobID: legacyResultID,
            errorCode: nil,
            errorMessage: nil,
            providerCallMetrics: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(legacy).write(
            to: directory.appendingPathComponent(
                StarterActionJobStore.recordFilename),
            options: [.atomic])

        let store = StarterActionJobStore(root: root)
        let current = try store.ensureJobs(characterID: characterID)
        let sleep = current.first { $0.actionID == .sleep }!
        expect(current.count == 4 && sleep.id != legacyID,
               "a changed paid sleep contract receives one fresh current card")
        expect(sleep.contractRevision == 3
               && sleep.estimatedProviderCalls == 2
               && sleep.completedBatches == 0,
               "the replacement card uses the safe-zone prone sleep contract")
        let preserved = try store.record(jobID: legacyID)
        expect(preserved.state == .awaitingReview
               && preserved.usedProviderCalls == 3
               && preserved.resultJobID == legacyResultID,
               "the old paid result remains intact as historical evidence")
        expect(store.jobs(characterID: characterID).filter {
            $0.actionID == .sleep
        }.count == 1,
               "Studio exposes only the current sleep contract")
    }

    static func testFailedAndCancelledProviderCallsKeepLatencyEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-provider-metrics-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StarterActionJobStore(root: root)
        let jobs = try store.ensureJobs(characterID: characterID)
        let wall = jobs.first { $0.actionID == .wall }!
        _ = try store.queue(
            jobID: wall.id, requestID: UUID().uuidString, quality: "medium")
        _ = try store.markGenerating(
            jobID: wall.id, phase: "batch-1", completedBatches: 0,
            usedProviderCalls: 0)
        let failed = try store.markFailed(
            jobID: wall.id, code: "provider_failed", message: "fixture",
            usedProviderCalls: 1,
            providerMetric: StarterActionProviderCallMetric(
                batchIndex: 0, durationSeconds: 44.5, outcome: .failed))
        expect(failed.providerCallMetrics == [
            StarterActionProviderCallMetric(
                batchIndex: 0, durationSeconds: 44.5, outcome: .failed),
        ], "a failed paid call keeps its latency and outcome")

        let tennis = jobs.first { $0.actionID == .tennis }!
        _ = try store.queue(
            jobID: tennis.id, requestID: UUID().uuidString, quality: "high")
        _ = try store.markGenerating(
            jobID: tennis.id, phase: "batch-1", completedBatches: 0,
            usedProviderCalls: 0)
        let cancelled = try store.cancel(
            jobID: tennis.id, usedProviderCalls: 1,
            providerMetric: StarterActionProviderCallMetric(
                batchIndex: 0, durationSeconds: 3.25,
                outcome: .cancelled))
        expect(cancelled.usedProviderCalls == 1
               && cancelled.providerCallMetrics?.first?.outcome == .cancelled,
               "cancelling a submitted call preserves possible spend and latency")
        let runtime = store.runtimeDictionary(for: cancelled)
        expect((runtime["providerCallMetrics"] as? [[String: Any]])?.count == 1,
               "Settings receives durable provider telemetry")
    }

    static func testDeleteJobsIsScopedIdempotentAndRejectsPathEscape() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "mimo-starter-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let store = StarterActionJobStore(root: root)
        let target = try store.ensureJobs(characterID: characterID)
        let retained = try store.ensureJobs(characterID: otherCharacterID)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let rogue = root.appendingPathComponent(StarterActionJobStore.folderName)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createSymbolicLink(at: rogue, withDestinationURL: outside)

        let deletedCount = try store.deleteJobs(characterID: characterID)
        expect(deletedCount == target.count,
               "deletion should remove all and only the target familiar's checkpoints")
        expect(store.jobs(characterID: characterID).isEmpty,
               "deleted starter-action checkpoints should not be listed")
        expect(store.jobs(characterID: otherCharacterID) == retained,
               "another familiar's starter-action checkpoints must remain untouched")
        expect(fm.fileExists(atPath: marker.path),
               "a symlinked job-looking directory must never delete its target")
        let repeatedCount = try store.deleteJobs(characterID: characterID)
        expect(repeatedCount == 0,
               "repeated starter-action deletion should be a no-op")
        expectThrows("starter deletion must reject path-like character IDs") {
            _ = try store.deleteJobs(characterID: "custom:../../outside")
        }
    }

    static func main() throws {
        try testEnsureCreatesOneDurableCardPerStarterAction()
        try testJobMovesThroughPaidAndLocalPhasesIntoReview()
        try testRestartFailsClosedWithoutRepeatingPaidWork()
        try testRevisedSleepKeepsPaidLegacyAndCreatesANewCurrentCard()
        try testFailedAndCancelledProviderCallsKeepLatencyEvidence()
        try testDeleteJobsIsScopedIdempotentAndRejectsPathEscape()
        print("starter action job tests passed")
    }
}
