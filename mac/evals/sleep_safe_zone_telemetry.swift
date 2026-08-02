import Foundation

struct DIYSleepSafeZoneCall: Codable, Equatable {
    let packIndex: Int
    let batchIndex: Int
    let durationSeconds: Double
    let outcome: String
    let estimatedCostUSD: Double
    let outputFilename: String?
    let usage: [String: Int]?
    let error: String?
}

struct DIYSleepSafeZoneResult: Codable, Equatable {
    let packIndex: Int
    let passed: Bool
    let stripFilename: String?
    let error: String?
}

struct DIYSleepSafeZoneEvidence: Codable, Equatable {
    static let schemaVersion = 1
    static let dataset = "mimo-sleep-safe-zone-v1"
    static let actionID = "sleep"
    static let contractRevision = 3
    static let packCount = 12
    static let baselineEvidenceSHA256 =
        "696dfbe529e51594c6f1ad3254f4ae59ea577b854d583bae82550d7148d2ba81"

    let schemaVersion: Int
    let dataset: String
    let actionID: String
    let contractRevision: Int
    let runtimeCommit: String
    let contractFingerprint: String
    let inputFingerprint: String
    let quality: String
    let packCount: Int
    let baselineEvidenceSHA256: String
    let historicalMixedFailures: Int
    let historicalMixedCount: Int
    let historicalSleepFailures: Int
    let historicalSleepCount: Int
    let createdAt: String
    var updatedAt: String
    var calls: [DIYSleepSafeZoneCall]
    var results: [DIYSleepSafeZoneResult]

    func validated() throws -> DIYSleepSafeZoneSummary {
        guard schemaVersion == Self.schemaVersion,
              dataset == Self.dataset,
              actionID == Self.actionID,
              contractRevision == Self.contractRevision,
              packCount == Self.packCount,
              baselineEvidenceSHA256 == Self.baselineEvidenceSHA256,
              historicalMixedFailures == 1,
              historicalMixedCount == 12,
              historicalSleepFailures == 1,
              historicalSleepCount == 3,
              runtimeCommit.range(
                of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              Self.isSHA256(contractFingerprint),
              Self.isSHA256(inputFingerprint),
              ["medium", "high"].contains(quality) else {
            throw DIYSleepSafeZoneTelemetryError.invalidEnvelope
        }
        guard calls.count == Self.packCount * 2,
              results.count == Self.packCount else {
            throw DIYSleepSafeZoneTelemetryError.incompleteCohort
        }

        var callCounts: [String: Int] = [:]
        for call in calls {
            let expectedFilename = String(format:
                "pack-%02d/sleep-batch-%02d.png",
                call.packIndex + 1, call.batchIndex + 1)
            guard (0..<Self.packCount).contains(call.packIndex),
                  (0..<2).contains(call.batchIndex),
                  call.durationSeconds.isFinite,
                  (0...3_600).contains(call.durationSeconds),
                  call.estimatedCostUSD.isFinite,
                  (0...10).contains(call.estimatedCostUSD),
                  ["success", "failed", "timed_out", "cancelled"]
                    .contains(call.outcome),
                  call.outcome == "success"
                    ? call.outputFilename == expectedFilename
                    : call.outputFilename == nil else {
                throw DIYSleepSafeZoneTelemetryError.invalidCall
            }
            callCounts["\(call.packIndex):\(call.batchIndex)", default: 0] += 1
        }
        for pack in 0..<Self.packCount {
            for batch in 0..<2 where callCounts["\(pack):\(batch)"] != 1 {
                throw DIYSleepSafeZoneTelemetryError.incompleteCohort
            }
        }

        var resultCounts: [Int: Int] = [:]
        for result in results {
            let expectedFilename = String(
                format: "pack-%02d/sleep-strip.png", result.packIndex + 1)
            guard (0..<Self.packCount).contains(result.packIndex),
                  result.passed
                    ? result.stripFilename == expectedFilename
                    : result.stripFilename == nil else {
                throw DIYSleepSafeZoneTelemetryError.invalidResult
            }
            resultCounts[result.packIndex, default: 0] += 1
        }
        guard (0..<Self.packCount).allSatisfy({ resultCounts[$0] == 1 }) else {
            throw DIYSleepSafeZoneTelemetryError.incompleteCohort
        }

        let successfulCalls = calls.filter { $0.outcome == "success" }.count
        let passedResults = results.filter(\.passed).count
        return DIYSleepSafeZoneSummary(
            sampleCount: Self.packCount,
            callCount: calls.count,
            callSuccessRate: Double(successfulCalls) / Double(calls.count),
            actionSuccessRate: Double(passedResults) / Double(results.count),
            failedPackCount: results.count - passedResults,
            estimatedCostUSD: calls.map(\.estimatedCostUSD).reduce(0, +),
            durationsSeconds: calls.map(\.durationSeconds))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

struct DIYSleepSafeZoneSummary: Equatable {
    let sampleCount: Int
    let callCount: Int
    let callSuccessRate: Double
    let actionSuccessRate: Double
    let failedPackCount: Int
    let estimatedCostUSD: Double
    let durationsSeconds: [Double]

    var passesTarget: Bool {
        sampleCount == DIYSleepSafeZoneEvidence.packCount
            && callSuccessRate >= 0.99
            && failedPackCount == 0
    }
}

enum DIYSleepSafeZoneTelemetryError: Error {
    case invalidEnvelope
    case invalidCall
    case invalidResult
    case incompleteCohort
}
