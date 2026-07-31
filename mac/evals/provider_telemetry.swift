import Foundation

enum DIYProviderTelemetryRole: String, Codable {
    case baseline
    case candidate
}

struct DIYProviderTelemetryCall: Codable, Equatable {
    let actionID: String
    let batchIndex: Int
    let durationSeconds: Double
    let outcome: String
    let estimatedCostUSD: Double
    let outputFilename: String?
    let usage: [String: Int]?
    let error: String?
}

struct DIYProviderTelemetryAction: Codable, Equatable {
    let actionID: String
    let passed: Bool
    let stripFilename: String?
    let error: String?
}

struct DIYProviderTelemetryEvidence: Codable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let dataset: String
    let role: DIYProviderTelemetryRole
    let cohortID: String
    let runtimeCommit: String
    let contractFingerprint: String
    let inputFingerprint: String
    let quality: String
    let packCount: Int
    let createdAt: String
    var updatedAt: String
    var calls: [DIYProviderTelemetryCall]
    var actions: [DIYProviderTelemetryAction]

    func validated(expectedRole: DIYProviderTelemetryRole,
                   expectedDataset: String) throws -> DIYProviderTelemetrySummary {
        guard schemaVersion == Self.schemaVersion,
              role == expectedRole,
              dataset == expectedDataset,
              cohortID.range(
                of: "^[a-z0-9][a-z0-9-]{2,63}$",
                options: .regularExpression) != nil,
              runtimeCommit.range(
                of: "^[0-9a-f]{40}$",
                options: .regularExpression) != nil,
              Self.isSHA256(contractFingerprint),
              Self.isSHA256(inputFingerprint),
              ["low", "medium", "high"].contains(quality),
              (1...20).contains(packCount) else {
            throw DIYProviderTelemetryError.invalidEnvelope
        }
        let expectedBatches: [String: Int] = [
            "gaze": 3, "sleep": 2, "tennis": 3, "wall": 2,
        ]
        guard calls.count == expectedBatches.values.reduce(0, +) * packCount,
              actions.count == expectedBatches.count * packCount else {
            throw DIYProviderTelemetryError.incompleteCohort
        }
        var counts: [String: Int] = [:]
        for call in calls {
            guard let batchCount = expectedBatches[call.actionID],
                  (0..<batchCount).contains(call.batchIndex),
                  call.durationSeconds.isFinite,
                  (0...3_600).contains(call.durationSeconds),
                  call.estimatedCostUSD.isFinite,
                  (0...10).contains(call.estimatedCostUSD),
                  ["success", "failed", "timed_out", "cancelled"]
                    .contains(call.outcome) else {
                throw DIYProviderTelemetryError.invalidCall
            }
            counts["\(call.actionID):\(call.batchIndex)", default: 0] += 1
        }
        for (action, batchCount) in expectedBatches {
            for batch in 0..<batchCount where counts["\(action):\(batch)"] != packCount {
                throw DIYProviderTelemetryError.incompleteCohort
            }
        }
        var actionCounts: [String: Int] = [:]
        for action in actions {
            guard expectedBatches[action.actionID] != nil else {
                throw DIYProviderTelemetryError.invalidAction
            }
            actionCounts[action.actionID, default: 0] += 1
        }
        guard expectedBatches.keys.allSatisfy({ actionCounts[$0] == packCount }) else {
            throw DIYProviderTelemetryError.incompleteCohort
        }
        let successCalls = calls.filter { $0.outcome == "success" }.count
        let successfulActions = actions.filter(\.passed).count
        return DIYProviderTelemetrySummary(
            durationsSeconds: calls.map(\.durationSeconds),
            unitCostUSD: calls.map(\.estimatedCostUSD).reduce(0, +)
                / Double(packCount),
            callSuccessRate: Double(successCalls) / Double(calls.count),
            actionSuccessRate: Double(successfulActions) / Double(actions.count),
            sampleCount: calls.count,
            contractFingerprint: contractFingerprint,
            inputFingerprint: inputFingerprint,
            quality: quality,
            runtimeCommit: runtimeCommit)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

struct DIYProviderTelemetrySummary: Equatable {
    let durationsSeconds: [Double]
    let unitCostUSD: Double
    let callSuccessRate: Double
    let actionSuccessRate: Double
    let sampleCount: Int
    let contractFingerprint: String
    let inputFingerprint: String
    let quality: String
    let runtimeCommit: String
}

enum DIYProviderTelemetryError: Error {
    case invalidEnvelope
    case invalidCall
    case invalidAction
    case incompleteCohort
}
