// sources: starter_action.swift starter_action_job.swift
import Foundation

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
        expect(Set(first.map(\.id)).count == 4, "every action has its own durable job")
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

        let generating = try store.markGenerating(
            jobID: gaze.id, phase: "batch-2-of-2",
            completedBatches: 1, usedProviderCalls: 2)
        expect(generating.state == .generating && generating.completedBatches == 1,
               "provider progress is durable")
        expect(generating.usedProviderCalls == 2,
               "actual paid calls remain visible")

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
            completedBatches: 1, usedProviderCalls: 1)
        store = nil

        let recovered = StarterActionJobStore(root: root)
            .jobs(characterID: characterID).first { $0.actionID == .sleep }!
        expect(recovered.state == .failed && recovered.errorCode == "interrupted",
               "an in-flight restart becomes an honest retryable failure")
        expect(recovered.usedProviderCalls == 1 && recovered.attempt == 1,
               "recovery preserves spend and attempt history")
        expect(recovered.requestID == nil,
               "no stale request ID can resume or duplicate a provider call")
        expect(recovered.canStart,
               "the user can explicitly retry after seeing the interruption")
    }

    static func main() throws {
        try testEnsureCreatesOneDurableCardPerStarterAction()
        try testJobMovesThroughPaidAndLocalPhasesIntoReview()
        try testRestartFailsClosedWithoutRepeatingPaidWork()
        print("starter action job tests passed")
    }
}
