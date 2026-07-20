// sources: consistency_metric.swift action_sheet_run.swift
import CoreGraphics
import Foundation

@main
struct ActionSheetRunTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func report(_ verdict: ConsistencyVerdict, distances: [Float]) -> ConsistencyReport {
        let readings = distances.enumerated().map {
            ConsistencyReading(index: $0.offset, distance: $0.element,
                               subjectHeight: 400, coverage: 0.3)
        }
        return ConsistencyReport(readings: readings, verdict: verdict)
    }

    static func attempt(_ index: Int, _ verdict: ConsistencyVerdict,
                        distances: [Float] = [5, 5, 5], cost: Decimal = 0.06)
        -> ActionSheetAttempt {
        ActionSheetAttempt(index: index, report: report(verdict, distances: distances), cost: cost)
    }

    // MARK: - Happy path

    static func testAPassingSheetIsAccepted() {
        let decision = ActionSheetRunDirector.decide(attempts: [attempt(0, .pass)])
        expect(decision == .accept(attemptIndex: 0), "a passing sheet installs, got \(decision)")
    }

    static func testAcceptanceStopsSpending() {
        let decision = ActionSheetRunDirector.decide(
            attempts: [attempt(0, .repairCells([1])), attempt(1, .pass)])
        expect(decision == .accept(attemptIndex: 1),
               "once a sheet passes, no further attempt is made")
    }

    // MARK: - Graded repair

    /// Repair targets the actual problem and costs less than a full reroll, so
    /// it is preferred while attempts remain.
    static func testDriftedCellsArePreferredForRepair() {
        let decision = ActionSheetRunDirector.decide(attempts: [attempt(0, .repairCells([2, 5]))])
        expect(decision == .repairCells([2, 5]), "drifted cells are repaired, got \(decision)")
    }

    static func testWildSheetIsRerolledWithItsReason() {
        let decision = ActionSheetRunDirector.decide(
            attempts: [attempt(0, .rerollSheet("cell 4 is too far from the reference"))])
        guard case .rerollSheet(let reason) = decision else {
            preconditionFailure("expected a reroll, got \(decision)")
        }
        expect(reason.contains("cell 4"), "the reason is carried through: \(reason)")
    }

    // MARK: - The spend cap

    /// The rule that keeps a stubborn character from quietly costing several
    /// times what the user was told.
    static func testAutomationStopsAfterThreeAttempts() {
        let attempts = (0..<3).map { attempt($0, .repairCells([1])) }
        let decision = ActionSheetRunDirector.decide(attempts: attempts)
        guard case .surrenderToUser(_, let reason) = decision else {
            preconditionFailure("expected surrender after three attempts, got \(decision)")
        }
        expect(reason.contains("3 attempts"), "the reason states the count: \(reason)")
    }

    static func testNeverExceedsTheCapEvenIfPushed() {
        let attempts = (0..<5).map { attempt($0, .rerollSheet("still wrong")) }
        let decision = ActionSheetRunDirector.decide(attempts: attempts)
        guard case .surrenderToUser = decision else {
            preconditionFailure("past the cap it must always surrender, got \(decision)")
        }
    }

    /// A misconfigured limit must not be able to uncap spending.
    static func testHardCeilingOverridesConfiguration() {
        let reckless = ActionSheetRunPolicy(maximumAttempts: 99, hardAttemptCeiling: 4)
        expect(reckless.effectiveAttemptLimit == 4,
               "the hard ceiling wins over configuration, got \(reckless.effectiveAttemptLimit)")

        let attempts = (0..<4).map { attempt($0, .repairCells([0])) }
        let decision = ActionSheetRunDirector.decide(attempts: attempts, policy: reckless)
        guard case .surrenderToUser = decision else {
            preconditionFailure("the ceiling must still stop the run, got \(decision)")
        }
    }

    // MARK: - Choosing what to show

    /// Ranked by worst cell, not mean. One badly broken frame is worse to look
    /// at than a sheet that is uniformly slightly off, and the mean hides it.
    static func testBestAttemptIsRankedByWorstCell() {
        let uniform = attempt(0, .repairCells([0]), distances: [9.5, 9.5, 9.5])   // mean 9.5, worst 9.5
        let lopsided = attempt(1, .repairCells([2]), distances: [4, 4, 12])       // mean 6.7, worst 12
        let best = ActionSheetRunDirector.bestAttempt([uniform, lopsided])
        expect(best.index == 0,
               "the uniformly-close sheet is the better one to show, got attempt \(best.index)")
    }

    static func testSurrenderShowsTheBestAttemptNotTheLast() {
        let attempts = [
            attempt(0, .repairCells([0]), distances: [9.2, 9.2, 9.2]),
            attempt(1, .repairCells([0]), distances: [4, 4, 20]),
            attempt(2, .repairCells([0]), distances: [4, 4, 18]),
        ]
        let decision = ActionSheetRunDirector.decide(attempts: attempts)
        guard case .surrenderToUser(let index, _) = decision else {
            preconditionFailure("expected surrender, got \(decision)")
        }
        expect(index == 0, "the closest attempt is shown, not the most recent, got \(index)")
    }

    // MARK: - Never silent about money

    static func testSpendIsAlwaysReported() {
        let attempts = [attempt(0, .repairCells([1]), cost: 0.06),
                        attempt(1, .repairCells([1]), cost: 0.06)]
        for decision: ActionSheetDecision in [
            .accept(attemptIndex: 1),
            .repairCells([1]),
            .rerollSheet(reason: "drifted"),
            .surrenderToUser(bestAttemptIndex: 0, reason: "stopped after 2 attempts"),
        ] {
            let summary = ActionSheetRunDirector.userFacingSummary(
                attempts: attempts, decision: decision)
            expect(summary.contains("spent"),
                   "every outcome must state the spend: '\(summary)'")
        }
    }

    static func testFirstTrySuccessSaysSo() {
        let summary = ActionSheetRunDirector.userFacingSummary(
            attempts: [attempt(0, .pass)], decision: .accept(attemptIndex: 0))
        expect(summary.contains("first try"), "a clean first result should say so: '\(summary)'")
    }

    static func testRetryCountIsVisibleToTheUser() {
        let attempts = (0..<3).map { attempt($0, .repairCells([1])) }
        let summary = ActionSheetRunDirector.userFacingSummary(
            attempts: attempts,
            decision: .surrenderToUser(bestAttemptIndex: 1, reason: "stopped after 3 attempts"))
        expect(summary.contains("3 attempts"), "the attempt count is surfaced: '\(summary)'")
        expect(summary.contains("attempt 2"), "which attempt is shown is stated: '\(summary)'")
    }

    static func testCostsAccumulateAcrossAttempts() {
        let attempts = [attempt(0, .pass, cost: 0.06), attempt(1, .pass, cost: 0.09)]
        expect(ActionSheetRunDirector.totalCost(attempts) == Decimal(string: "0.15"),
               "spend is the sum of every attempt, not just the last")
    }

    // MARK: - Frame numbering

    /// Users count frames from one; the code counts from zero.
    static func testUserFacingFramesAreOneBased() {
        let summary = ActionSheetRunDirector.userFacingSummary(
            attempts: [attempt(0, .repairCells([0, 4]))], decision: .repairCells([0, 4]))
        expect(summary.contains("1, 5"), "frames are presented one-based: '\(summary)'")
    }

    // MARK: - Development retention

    static func testJournalLineCarriesTheScores() {
        let line = ActionSheetRetention.journalLine(
            characterID: "custom:abc", stage: "bloom",
            attempt: attempt(1, .repairCells([2]), distances: [5.1, 5.4, 11.2]))
        expect(line.contains("attempt=2"), "attempt number is one-based in the log")
        expect(line.contains("custom:abc") && line.contains("bloom"), "identifies the subject")
        expect(line.contains("11.2"), "carries the distances used for calibration")
    }

    static func main() {
        testAPassingSheetIsAccepted()
        testAcceptanceStopsSpending()
        testDriftedCellsArePreferredForRepair()
        testWildSheetIsRerolledWithItsReason()
        testAutomationStopsAfterThreeAttempts()
        testNeverExceedsTheCapEvenIfPushed()
        testHardCeilingOverridesConfiguration()
        testBestAttemptIsRankedByWorstCell()
        testSurrenderShowsTheBestAttemptNotTheLast()
        testSpendIsAlwaysReported()
        testFirstTrySuccessSaysSo()
        testRetryCountIsVisibleToTheUser()
        testCostsAccumulateAcrossAttempts()
        testUserFacingFramesAreOneBased()
        testJournalLineCarriesTheScores()
        print("action sheet run: all assertions passed")
    }
}
