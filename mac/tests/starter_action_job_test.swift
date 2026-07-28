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

    static func testEnsureCreatesOneDurableCardPerStarterAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-starter-jobs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = StarterActionJobStore(root: root)
        let first = try store.ensureJobs(characterID: characterID)
        let second = try store.ensureJobs(characterID: characterID)

        expect(first.map(\.actionID) == StarterActionID.allCases,
               "Studio receives starter jobs in product order")
        expect(Set(first.map(\.id)).count == 5, "every action has its own durable job")
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
                pngData: makeBatchPNG(), usedProviderCalls: batchIndex + 1)
        }
        let completedGaze = try store.record(jobID: gaze.id)
        expect(completedGaze.usedProviderCalls == gaze.estimatedProviderCalls,
               "every completed paid call remains visible")

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
            jobID: sleep.id, phase: "batch-2-of-3",
            completedBatches: 0, usedProviderCalls: 0)
        let completed = try store!.storeCompletedBatch(
            jobID: sleep.id, batchIndex: 0,
            pngData: makeBatchPNG(), usedProviderCalls: 1)
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

    static func main() throws {
        try testEnsureCreatesOneDurableCardPerStarterAction()
        try testJobMovesThroughPaidAndLocalPhasesIntoReview()
        try testRestartFailsClosedWithoutRepeatingPaidWork()
        print("starter action job tests passed")
    }
}
