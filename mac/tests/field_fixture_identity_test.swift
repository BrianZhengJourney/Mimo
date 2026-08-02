// sources: evals/field_fixture_identity.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func record(
    state: String = "awaiting_review",
    updatedAt: Double = 100,
    quality: String = "medium",
    completedBatches: Int = 2,
    estimatedProviderCalls: Int = 2,
    contractRevision: Any = 2
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "id": "157c3e15-bd60-4a07-8526-593c793cc214",
        "characterID": "custom:e3851869-e455-44ba-8520-8df00031a1c8",
        "actionID": "sleep",
        "contractRevision": contractRevision,
        "state": state,
        "phase": state.replacingOccurrences(of: "_", with: "-"),
        "createdAt": 50,
        "updatedAt": updatedAt,
        "attempt": 1,
        "maximumAttempts": 3,
        "requestID": "mutable-request",
        "quality": quality,
        "completedBatches": completedBatches,
        "estimatedProviderCalls": estimatedProviderCalls,
        "usedProviderCalls": 2,
        "resultJobID": state == "installed" ? "mutable-result" : NSNull(),
        "errorCode": NSNull(),
        "errorMessage": NSNull(),
        "providerCallMetrics": [],
    ], options: [.sortedKeys])
}

@main
struct FieldFixtureIdentityTests {
    static func main() throws {
        let review = try DIYFieldFixtureIdentity(recordData: record())
        let installed = try DIYFieldFixtureIdentity(
            recordData: record(state: "installed", updatedAt: 900,
                               completedBatches: 1))
        expect(review == installed,
               "workflow state and timestamps must not invalidate retained art")

        let differentQuality = try DIYFieldFixtureIdentity(
            recordData: record(quality: "high"))
        expect(review != differentQuality,
               "provider quality remains part of fixed fixture identity")

        let differentCallContract = try DIYFieldFixtureIdentity(
            recordData: record(estimatedProviderCalls: 3))
        expect(review != differentCallContract,
               "provider call contract remains pinned")

        let legacy = try DIYFieldFixtureIdentity(
            recordData: record(contractRevision: NSNull()))
        let explicitRevisionOne = try DIYFieldFixtureIdentity(
            recordData: record(contractRevision: 1))
        expect(legacy == explicitRevisionOne,
               "legacy nil contract revision normalizes to revision one")

        let malformed = Data("{\"state\":\"installed\"}".utf8)
        expect((try? DIYFieldFixtureIdentity(recordData: malformed)) == nil,
               "missing generation identity fields must fail closed")

        print("field fixture identity tests passed")
    }
}
