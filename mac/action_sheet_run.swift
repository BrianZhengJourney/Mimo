import Foundation

// Decides what to do after an action sheet comes back: ship it, repair some
// cells, reroll the whole thing, or stop and hand the best attempt to the user.
//
// Pure policy, no networking and no image work, so the spend rules are testable
// without touching an API. That matters more here than anywhere else in the
// pipeline: every decision this makes costs real money, and the failure mode is
// silent — a user who was told "one call" watching a stubborn character quietly
// consume several.
//
// The rule, per docs/companion/06-open-questions.md:
//   at most 3 automatic attempts, then stop and show the best one with its
//   score, and never hide what was spent.

struct ActionSheetAttempt {
    let index: Int
    let report: ConsistencyReport
    /// What this attempt cost, in whatever unit the caller accounts in.
    let cost: Decimal
}

enum ActionSheetDecision: Equatable {
    /// Good enough — install it.
    case accept(attemptIndex: Int)
    /// Regenerate only these cells, through the existing single-stage path.
    case repairCells([Int])
    /// Regenerate the whole sheet.
    case rerollSheet(reason: String)
    /// Out of automatic attempts. Show the best one and let the user decide.
    case surrenderToUser(bestAttemptIndex: Int, reason: String)
}

struct ActionSheetRunPolicy {
    /// Total automatic generations of one sheet, the first included.
    ///
    /// Three rather than two so a stubborn character gets a real chance, and so
    /// development can compare attempts 1 through 3 and see whether the third
    /// ever actually beats the second. If it does not, this should drop to two.
    let maximumAttempts: Int
    /// Independent of any configuration, so a bad config cannot uncap spending.
    let hardAttemptCeiling: Int

    static let standard = ActionSheetRunPolicy(maximumAttempts: 3, hardAttemptCeiling: 4)

    var effectiveAttemptLimit: Int { min(maximumAttempts, hardAttemptCeiling) }
}

enum ActionSheetRunDirector {
    /// Chooses the next move given every attempt so far.
    ///
    /// `attempts` must be in generation order and non-empty.
    static func decide(attempts: [ActionSheetAttempt],
                       policy: ActionSheetRunPolicy = .standard) -> ActionSheetDecision {
        guard let latest = attempts.last else {
            return .rerollSheet(reason: "no attempt has been made yet")
        }

        if case .pass = latest.report.verdict {
            return .accept(attemptIndex: latest.index)
        }

        let remaining = policy.effectiveAttemptLimit - attempts.count
        guard remaining > 0 else {
            let best = bestAttempt(attempts)
            return .surrenderToUser(
                bestAttemptIndex: best.index,
                reason: "stopped after \(attempts.count) attempts; showing the closest one "
                      + "(worst cell \(String(format: "%.2f", best.report.worstDistance)))")
        }

        switch latest.report.verdict {
        case .pass:
            return .accept(attemptIndex: latest.index)
        case .repairCells(let cells):
            // Repairing is cheaper than a full reroll and targets the actual
            // problem, so it is preferred while attempts remain.
            return .repairCells(cells)
        case .rerollSheet(let reason):
            return .rerollSheet(reason: reason)
        }
    }

    /// The attempt a user should be shown when automation gives up.
    ///
    /// Ranked by worst cell rather than mean: a sheet with one badly broken
    /// frame is worse to look at than one that is uniformly a little off, and
    /// the mean hides exactly that.
    static func bestAttempt(_ attempts: [ActionSheetAttempt]) -> ActionSheetAttempt {
        attempts.min {
            if $0.report.worstDistance != $1.report.worstDistance {
                return $0.report.worstDistance < $1.report.worstDistance
            }
            return $0.report.meanDistance < $1.report.meanDistance
        } ?? attempts[0]
    }

    static func totalCost(_ attempts: [ActionSheetAttempt]) -> Decimal {
        attempts.reduce(Decimal(0)) { $0 + $1.cost }
    }

    /// What the user is told. Never silent about attempts or spend — someone
    /// promised "one call" should not discover three on their statement.
    static func userFacingSummary(attempts: [ActionSheetAttempt],
                                  decision: ActionSheetDecision) -> String {
        let spent = totalCost(attempts)
        let cost = "spent so far: \(spent)"
        switch decision {
        case .accept(let index):
            return attempts.count == 1
                ? "Generated on the first try. \(cost)"
                : "Accepted attempt \(index + 1) of \(attempts.count). \(cost)"
        case .repairCells(let cells):
            let list = cells.map { String($0 + 1) }.joined(separator: ", ")
            return "Redrawing frame\(cells.count == 1 ? "" : "s") \(list). \(cost)"
        case .rerollSheet(let reason):
            return "Regenerating the sheet — \(reason). \(cost)"
        case .surrenderToUser(let index, let reason):
            return "\(reason). Showing attempt \(index + 1); accept it or try again. \(cost)"
        }
    }
}

// MARK: - Development retention

enum ActionSheetRetention {
    /// Whether to keep every attempt rather than only the best.
    ///
    /// Development keeps all of them, because the point of the retry cap is to
    /// be checked: seeing how attempts 1 through 3 differ is what decides
    /// where the thresholds sit, whether a bad sheet fails uniformly or in one
    /// cell, and whether a third attempt is ever better than the second. In
    /// release only the winner is kept — each draft is 5-15MB.
    static var keepsEveryAttempt: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "keepEveryActionSheetAttempt")
        #endif
    }

    /// One line per attempt for the calibration log.
    static func journalLine(characterID: String, stage: String,
                            attempt: ActionSheetAttempt) -> String {
        "\(characterID)\tstage=\(stage)\tattempt=\(attempt.index + 1)\t\(attempt.report.summary)"
    }
}
