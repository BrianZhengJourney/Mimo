// sources: pet_provider.swift custom_pet.swift character_sheet.swift pet_generation.swift action_sheet.swift consistency_metric.swift action_sheet_run.swift
// compile-only: paid end-to-end action sheet run; not safe to run unattended
// Opt-in, paid end-to-end run of the action-sheet pipeline: generate one
// sixteen-frame walk cycle for an installed familiar, slice it, score it
// against the mature stage frame, and let ActionSheetRunDirector decide.
//
// This is the first real execution of the whole loop — every stage before it
// (slicer, gate, thresholds, spend policy) is unit tested, but no sheet had
// ever been generated. Every attempt's raw sheet, sliced strip, and scores are
// written to OUTPUT_DIR so the thresholds can be checked against reality.
//
// Run (from the repository root, compiled by test.sh as a compile-only test):
//   action_sheet_live_run --confirm-paid OUTPUT_DIR PET_SHEET_PNG
//
// OPENAI_API_KEY may be set in the environment; otherwise MimoSecret reads the
// same login-keychain entry as the app. The key is never printed or persisted.

import AppKit
import Foundation
import ImageIO

private enum LiveRunError: LocalizedError {
    case usage
    case missingAPIKey
    case missingInput(String)
    case undecodableImage(String)
    case generationTimedOut
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: action_sheet_live_run --confirm-paid OUTPUT_DIR PET_SHEET_PNG [walk|gaze]"
        case .missingAPIKey:
            return "OpenAI API key is not configured in the environment or Mimo keychain."
        case .missingInput(let path):
            return "Input is missing or unreadable: \(path)"
        case .undecodableImage(let label):
            return "Could not decode \(label) into a CGImage."
        case .generationTimedOut:
            return "Generation did not complete within the harness deadline."
        case .generationFailed(let message):
            return "Generation failed: \(message)"
        }
    }
}

private func cgImage(fromPNG data: Data, label: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw LiveRunError.undecodableImage(label)
    }
    return image
}

private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@discardableResult
private func write(_ data: Data, named name: String, to directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try data.write(to: url, options: [.atomic])
    log("artifact  \(name)  \(data.count) bytes")
    return url
}

/// Waits for the staged generation by pumping the main run loop — the
/// coordinator delivers progress and completion on the main queue, so a
/// blocked main thread (a semaphore, say) waits forever on a result that is
/// sitting in its own queue. Exactly the mistake this file made first.
private func awaitSheet(coordinator: PetGenerationCoordinator,
                        requestID: String,
                        stageFrame: Data, styleBoard: Data?,
                        personalityVisual: String,
                        plan: PetActionSheetPlan,
                        timeout: TimeInterval) throws -> PetGenerationOutput {
    var outcome: Result<PetGenerationOutput, Error>?
    let startedAt = Date()
    coordinator.generateActionSheet(
        requestID: requestID, stage: .radiant,
        stageFrameData: stageFrame, styleBoardData: styleBoard,
        personalityVisual: personalityVisual, quality: .medium,
        plan: plan,
        progress: { phase, _, _ in
            log("phase     \(phase)  +\(Int(Date().timeIntervalSince(startedAt)))s")
        },
        completion: { result in
            outcome = result
        })
    let deadline = Date(timeIntervalSinceNow: timeout)
    while outcome == nil && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default,
                                    before: min(deadline, Date(timeIntervalSinceNow: 0.1)))
        }
    }
    switch outcome {
    case .success(let output): return output
    case .failure(let error): throw LiveRunError.generationFailed("\(error)")
    case nil:
        coordinator.cancel(requestID)
        throw LiveRunError.generationTimedOut
    }
}

@main
struct ActionSheetLiveRun {
    static func main() {
        do { try run() } catch {
            log("FAILED    \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard (4...5).contains(arguments.count), arguments[1] == "--confirm-paid" else {
            throw LiveRunError.usage
        }
        let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let sheetURL = URL(fileURLWithPath: arguments[3])
        let plan: PetActionSheetPlan
        switch arguments.count > 4 ? arguments[4] : "walk" {
        case "walk": plan = .walkCycle
        case "gaze": plan = .gaze
        case "rest": plan = .rest
        case "wall": plan = .wallLean
        default: throw LiveRunError.usage
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        guard let sheetData = try? Data(contentsOf: sheetURL) else {
            throw LiveRunError.missingInput(sheetURL.path)
        }
        guard let key = MimoSecret.openAI.read() else { throw LiveRunError.missingAPIKey }
        log("credential ok (source not printed)")

        // The mature slice is both the identity lock sent to the model and the
        // reference every returned cell is scored against — same stage on both
        // sides, which is the rule the thresholds were calibrated under.
        let matureFrame = try CharacterSheetProcessor.extractNormalizedStage(
            fromNormalizedSheet: sheetData, stageIndex: 2)
        try write(matureFrame, named: "reference-mature-frame.png", to: outputDirectory)
        let reference = try cgImage(fromPNG: matureFrame, label: "mature frame")

        let styleBoardPath = "mac/assets/style-reference/mimo-style-reference-board.png"
        let styleBoard = try? Data(contentsOf: URL(fileURLWithPath: styleBoardPath))
        log(styleBoard == nil ? "style board: not found, proceeding without"
                              : "style board: loaded")

        let profile = CustomPetTemperaments.profile(for: "quiet-curious")
        let coordinator = PetGenerationCoordinator(openAIKeyReader: { key })
        let policy = ActionSheetRunPolicy.standard
        var attempts: [ActionSheetAttempt] = []
        var strips: [Int: ActionSheetResult] = [:]

        while attempts.count < policy.effectiveAttemptLimit {
            let attemptIndex = attempts.count
            let requestID = "\(plan.key)-live-\(UUID().uuidString.lowercased())"
            log("attempt   \(attemptIndex + 1) of \(policy.effectiveAttemptLimit) — generating \(plan.key) (medium, 2048², 4x4)")
            let output = try awaitSheet(coordinator: coordinator, requestID: requestID,
                                        stageFrame: matureFrame, styleBoard: styleBoard,
                                        personalityVisual: profile.promptFragment,
                                        plan: plan,
                                        timeout: 480)
            try write(output.data, named: "attempt-\(attemptIndex + 1)-raw.png", to: outputDirectory)
            log("usage     \(output.usage.dictionary)")

            let report: ConsistencyReport
            do {
                let sliced = try ActionSheetProcessor.process(pngData: output.data)
                strips[attemptIndex] = sliced
                try write(sliced.pngData, named: "attempt-\(attemptIndex + 1)-strip.png",
                          to: outputDirectory)
                let cells = try sliced.sourceCells.enumerated().map { index, cell in
                    try cgImage(fromPNG: CharacterSheetProcessor.encodePNG(cell),
                                label: "cell \(index)")
                }
                report = try ConsistencyMetric.evaluate(cells: cells, reference: reference)
            } catch {
                // A sheet the slicer rejects outright scores as a full reroll:
                // record it so the money it cost is visible in the decision.
                log("slice     rejected — \(error)")
                report = ConsistencyReport(
                    readings: [],
                    verdict: .rerollSheet("slicing rejected the sheet: \(error)"))
            }
            let attempt = ActionSheetAttempt(index: attemptIndex, report: report, cost: 0.05)
            attempts.append(attempt)
            log("gate      " + ActionSheetRetention.journalLine(
                characterID: sheetURL.deletingLastPathComponent().lastPathComponent,
                stage: "radiant-\(plan.key)", attempt: attempt))

            let decision = ActionSheetRunDirector.decide(attempts: attempts, policy: policy)
            log("decision  \(decision)")
            log("summary   " + ActionSheetRunDirector.userFacingSummary(
                attempts: attempts, decision: decision))
            switch decision {
            case .accept(let index):
                if let final = strips[index] {
                    try write(final.pngData, named: "\(plan.key)-strip-final.png", to: outputDirectory)
                    let anchors = final.frames.map { "\($0.index):(\($0.anchorX),\($0.anchorY))" }
                    log("anchors   \(anchors.joined(separator: " "))")
                }
                log("RESULT    accepted attempt \(index + 1)")
                return
            case .surrenderToUser(let index, let reason):
                if let best = strips[index] {
                    try write(best.pngData, named: "\(plan.key)-strip-best-unaccepted.png",
                              to: outputDirectory)
                }
                log("RESULT    surrendered — \(reason)")
                return
            case .repairCells(let cells):
                // Single-cell repair has no generation path yet; a full reroll
                // is the honest fallback and the run log records the downgrade.
                log("repair    cells \(cells) requested; repair path not built — rerolling instead")
            case .rerollSheet(let reason):
                log("reroll    \(reason)")
            }
        }
        log("RESULT    attempt limit reached without acceptance")
    }
}
