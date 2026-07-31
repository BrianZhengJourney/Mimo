// sources: evals/diy_rollout.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private let baselineCommit = String(repeating: "a", count: 40)
private let candidateCommit = String(repeating: "b", count: 40)

private func evidence(label: String = "candidate",
                      commit: String = candidateCommit,
                      eligible: Bool = true,
                      gates: [String: Bool] = ["quality": true, "providerP95": true],
                      dataset: String = "mimo-diy-v3") -> DIYRolloutEvidence {
    DIYRolloutEvidence(
        schemaVersion: 1, dataset: dataset, label: label, commit: commit,
        comparison: DIYRolloutComparison(rolloutEligible: eligible, gates: gates))
}

@main
struct DIYRolloutTests {
    static func main() {
        let baseline = evidence(label: "baseline", commit: baselineCommit, eligible: false)
        let candidate = evidence()
        var ledger = DIYRolloutController.start(
            baseline: baseline, candidate: candidate, now: "t0")
        expect(ledger.status == .active && ledger.stagePercent == 5,
               "an eligible clean candidate should start at exactly 5%")

        ledger = DIYRolloutController.observe(candidate, ledger: ledger, now: "t1")
        expect(ledger.status == .active && ledger.stagePercent == 25,
               "a passing 5% observation should promote to 25%")
        ledger = DIYRolloutController.observe(candidate, ledger: ledger, now: "t2")
        expect(ledger.status == .active && ledger.stagePercent == 100,
               "a passing 25% observation should promote to 100%")
        ledger = DIYRolloutController.observe(candidate, ledger: ledger, now: "t3")
        expect(ledger.status == .complete && ledger.stagePercent == 100,
               "100% still needs one passing observation before completion")

        let missingProvider = evidence(
            eligible: false, gates: ["quality": true, "providerP95": false])
        let blocked = DIYRolloutController.start(
            baseline: baseline, candidate: missingProvider, now: "blocked")
        expect(blocked.status == .blocked && blocked.stagePercent == 0,
               "a missing provider gate must block the initial 5% rollout")
        expect(blocked.events.last?.failedGates.contains("providerP95") == true,
               "the blocked ledger should preserve the exact failed gate")

        let dirty = evidence(commit: candidateCommit + "-dirty")
        let dirtyBlocked = DIYRolloutController.start(
            baseline: baseline, candidate: dirty, now: "dirty")
        expect(dirtyBlocked.events.last?.failedGates.contains("candidateCommitClean") == true,
               "dirty candidate evidence must never enter rollout")

        let missingGateEvidence = DIYRolloutEvidence(
            schemaVersion: 1, dataset: "mimo-diy-v3", label: "malformed",
            commit: candidateCommit,
            comparison: DIYRolloutComparison(rolloutEligible: true, gates: nil))
        let missingGateBlocked = DIYRolloutController.start(
            baseline: baseline, candidate: missingGateEvidence, now: "missing-gates")
        expect(missingGateBlocked.events.last?.failedGates.contains("hardGatesPresent") == true,
               "rolloutEligible alone must not bypass missing hard-gate evidence")

        var active = DIYRolloutController.start(
            baseline: baseline, candidate: candidate, now: "start")
        active = DIYRolloutController.observe(
            missingProvider, ledger: active, now: "failure")
        expect(active.status == .rolledBack && active.stagePercent == 0,
               "any hard-gate failure during rollout must immediately roll back")

        let identifiers = (0..<10_000).map { "install-\($0)" }
        let five = Set(identifiers.filter {
            DIYRolloutCohort.includes(identifier: $0, percent: 5, salt: candidateCommit)
        })
        let twentyFive = Set(identifiers.filter {
            DIYRolloutCohort.includes(identifier: $0, percent: 25, salt: candidateCommit)
        })
        expect(five.isSubset(of: twentyFive),
               "the 5% cohort must be a stable subset of the 25% cohort")
        expect((400...600).contains(five.count) && (2_300...2_700).contains(twentyFive.count),
               "deterministic cohort buckets should approximate their requested percentages")
        expect(identifiers.allSatisfy {
            DIYRolloutCohort.includes(identifier: $0, percent: 100, salt: candidateCommit)
        }, "100% must include every identifier")

        print("DIY rollout tests passed")
    }
}
