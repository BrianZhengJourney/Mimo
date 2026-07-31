import Foundation

enum DIYRolloutStatus: String, Codable {
    case blocked
    case active
    case complete
    case rolledBack = "rolled_back"
}

struct DIYRolloutComparison: Codable {
    let rolloutEligible: Bool
    let gates: [String: Bool]?
}

struct DIYRolloutEvidence: Codable {
    let schemaVersion: Int
    let dataset: String
    let label: String
    let commit: String
    let comparison: DIYRolloutComparison

    var hasCleanCommit: Bool {
        commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    var failedGates: [String] {
        (comparison.gates ?? [:]).filter { !$0.value }.map(\.key).sorted()
    }
}

struct DIYRolloutEvent: Codable {
    let action: String
    let fromPercent: Int
    let toPercent: Int
    let evidenceLabel: String
    let evidenceCommit: String
    let failedGates: [String]
    let reason: String?
    let createdAt: String
}

struct DIYRolloutLedger: Codable {
    let schemaVersion: Int
    let dataset: String
    let baselineCommit: String
    let candidateCommit: String
    var status: DIYRolloutStatus
    var stagePercent: Int
    var events: [DIYRolloutEvent]

    var cohortSalt: String { candidateCommit }

    func includes(identifier: String) -> Bool {
        DIYRolloutCohort.includes(
            identifier: identifier, percent: stagePercent, salt: cohortSalt)
    }
}

enum DIYRolloutCohort {
    /// Deterministic and monotonic: every identifier in 5% is also in 25%,
    /// and every identifier is in 100%. The candidate commit changes the salt
    /// so unrelated releases do not permanently target the same people.
    static func includes(identifier: String, percent: Int, salt: String) -> Bool {
        guard percent > 0 else { return false }
        guard percent < 100 else { return true }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(salt):\(identifier)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % 100) < percent
    }
}

enum DIYRolloutController {
    static func start(baseline: DIYRolloutEvidence,
                      candidate: DIYRolloutEvidence,
                      now: String) -> DIYRolloutLedger {
        var failed = candidate.failedGates
        if !candidate.comparison.rolloutEligible {
            failed.append("rolloutEligible")
        }
        if !baseline.hasCleanCommit { failed.append("baselineCommitClean") }
        if !candidate.hasCleanCommit { failed.append("candidateCommitClean") }
        if baseline.schemaVersion != 1 || candidate.schemaVersion != 1 {
            failed.append("evidenceSchemaVersion")
        }
        if candidate.comparison.gates?.isEmpty != false {
            failed.append("hardGatesPresent")
        }
        if baseline.dataset != candidate.dataset { failed.append("datasetsMatch") }
        if baseline.commit == candidate.commit { failed.append("candidateDiffersFromBaseline") }
        failed = Array(Set(failed)).sorted()
        let accepted = failed.isEmpty
        let event = DIYRolloutEvent(
            action: accepted ? "start" : "block",
            fromPercent: 0, toPercent: accepted ? 5 : 0,
            evidenceLabel: candidate.label,
            evidenceCommit: candidate.commit,
            failedGates: failed,
            reason: accepted ? nil : "candidate did not satisfy every rollout prerequisite",
            createdAt: now)
        return DIYRolloutLedger(
            schemaVersion: 1,
            dataset: candidate.dataset,
            baselineCommit: baseline.commit,
            candidateCommit: candidate.commit,
            status: accepted ? .active : .blocked,
            stagePercent: accepted ? 5 : 0,
            events: [event])
    }

    static func observe(_ evidence: DIYRolloutEvidence,
                        ledger: DIYRolloutLedger,
                        now: String) -> DIYRolloutLedger {
        guard ledger.status == .active else { return ledger }
        var next = ledger
        var failed = evidence.failedGates
        if !evidence.comparison.rolloutEligible { failed.append("rolloutEligible") }
        if !evidence.hasCleanCommit { failed.append("candidateCommitClean") }
        if evidence.schemaVersion != 1 { failed.append("evidenceSchemaVersion") }
        if evidence.comparison.gates?.isEmpty != false { failed.append("hardGatesPresent") }
        if evidence.dataset != ledger.dataset { failed.append("datasetsMatch") }
        if evidence.commit != ledger.candidateCommit { failed.append("candidateCommitMatches") }
        failed = Array(Set(failed)).sorted()

        if !failed.isEmpty {
            next.status = .rolledBack
            next.stagePercent = 0
            next.events.append(DIYRolloutEvent(
                action: "rollback",
                fromPercent: ledger.stagePercent, toPercent: 0,
                evidenceLabel: evidence.label,
                evidenceCommit: evidence.commit,
                failedGates: failed,
                reason: "hard gate failed during rollout observation",
                createdAt: now))
            return next
        }

        let target: Int
        switch ledger.stagePercent {
        case 5: target = 25
        case 25: target = 100
        case 100: target = 100
        default: target = 0
        }
        if target == 0 {
            next.status = .rolledBack
            next.stagePercent = 0
            next.events.append(DIYRolloutEvent(
                action: "rollback",
                fromPercent: ledger.stagePercent, toPercent: 0,
                evidenceLabel: evidence.label,
                evidenceCommit: evidence.commit,
                failedGates: ["validRolloutStage"],
                reason: "invalid rollout stage",
                createdAt: now))
            return next
        }
        next.stagePercent = target
        next.status = ledger.stagePercent == 100 ? .complete : .active
        next.events.append(DIYRolloutEvent(
            action: ledger.stagePercent == 100 ? "complete" : "promote",
            fromPercent: ledger.stagePercent, toPercent: target,
            evidenceLabel: evidence.label,
            evidenceCommit: evidence.commit,
            failedGates: [], reason: nil, createdAt: now))
        return next
    }

    static func rollback(ledger: DIYRolloutLedger,
                         reason: String,
                         now: String) -> DIYRolloutLedger {
        var next = ledger
        let previous = ledger.stagePercent
        next.status = .rolledBack
        next.stagePercent = 0
        next.events.append(DIYRolloutEvent(
            action: "rollback", fromPercent: previous, toPercent: 0,
            evidenceLabel: "manual", evidenceCommit: ledger.candidateCommit,
            failedGates: [], reason: reason, createdAt: now))
        return next
    }
}
