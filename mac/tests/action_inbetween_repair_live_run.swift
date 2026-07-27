// sources: pet_provider.swift custom_pet.swift character_sheet.swift action_sheet.swift generation_draft.swift generation_ledger.swift style_reference.swift reference_preprocessor.swift pet_generation.swift
// compile-only: one paid OpenAI M13...M16 repair generation; opt-in only
// Run:
//   action_inbetween_repair_live_run --confirm-paid OUTPUT_DIR PET_SHEET KEYFRAME_RAW OLD_MIDPOINT_STRIP KEYFRAME_STRIP

import AppKit
import Foundation

private enum RepairRunError: LocalizedError {
    case usage
    case missingAPIKey
    case missingInput(String)
    case timedOut
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: action_inbetween_repair_live_run --confirm-paid OUTPUT_DIR PET_SHEET KEYFRAME_RAW OLD_MIDPOINT_STRIP KEYFRAME_STRIP"
        case .missingAPIKey: return "OpenAI API key is not configured."
        case .missingInput(let path): return "Input is missing or unreadable: \(path)"
        case .timedOut: return "Repair generation did not finish before the deadline."
        case .generationFailed(let message): return "Repair generation failed: \(message)"
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private func input(_ path: String) throws -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
        throw RepairRunError.missingInput(path)
    }
    return data
}

@discardableResult
private func write(_ data: Data, named name: String, to directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    log("artifact  \(name)  \(data.count) bytes")
    return url
}

private func awaitRepair(coordinator: PetGenerationCoordinator,
                         stageFrame: Data, keyframeSheet: Data,
                         guide: Data, styleBoard: Data?,
                         personalityVisual: String) throws -> PetGenerationOutput {
    let requestID = "walk-m13-m16-repair-\(UUID().uuidString.lowercased())"
    let startedAt = Date()
    var outcome: Result<PetGenerationOutput, Error>?
    coordinator.generateWalkInbetweenRepairSheet(
        requestID: requestID, stage: .radiant,
        stageFrameData: stageFrame, keyframeSheetData: keyframeSheet,
        motionGuideData: guide, styleBoardData: styleBoard,
        personalityVisual: personalityVisual, quality: .medium,
        progress: { phase, _, _ in
            log("phase     \(phase)  +\(Int(Date().timeIntervalSince(startedAt)))s")
        }, completion: { outcome = $0 })
    let deadline = Date(timeIntervalSinceNow: 360)
    while outcome == nil && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default,
                                    before: min(deadline, Date(timeIntervalSinceNow: 0.1)))
        }
    }
    switch outcome {
    case .success(let output): return output
    case .failure(let error): throw RepairRunError.generationFailed("\(error)")
    case nil:
        coordinator.cancel(requestID)
        throw RepairRunError.timedOut
    }
}

@main
struct ActionInbetweenRepairLiveRun {
    static func main() {
        do { try run() } catch {
            log("FAILED    \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 7, arguments[1] == "--confirm-paid" else {
            throw RepairRunError.usage
        }
        let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let petSheet = try input(arguments[3])
        let keyframeSheet = try input(arguments[4])
        let oldMidpoints = try input(arguments[5])
        let keyframeStrip = try input(arguments[6])
        guard let key = MimoSecret.openAI.read() else { throw RepairRunError.missingAPIKey }
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let stageFrame = try CharacterSheetProcessor.extractNormalizedStage(
            fromNormalizedSheet: petSheet, stageIndex: 2)
        try write(stageFrame, named: "reference-mature-frame.png", to: outputDirectory)
        let guide = try input("mac/assets/motion-reference/biped-walk-inbetweens-13-16.png")
        let styleMaster = try? input("mac/assets/style-reference/mimo-style-reference-board.png")
        let styleBoard = styleMaster.flatMap(MimoStyleReference.requestData(masterData:))
        log("preflight  1 paid call; repair M13...M16; medium; 1024x1024")
        log("references stage=\(stageFrame.count) keyframes=\(keyframeSheet.count) "
            + "guide=\(guide.count) style=\(styleBoard?.count ?? 0) bytes")

        let coordinator = PetGenerationCoordinator(openAIKeyReader: { key })
        let profile = CustomPetTemperaments.profile(for: "quiet-curious")
        let output = try awaitRepair(
            coordinator: coordinator, stageFrame: stageFrame,
            keyframeSheet: keyframeSheet, guide: guide, styleBoard: styleBoard,
            personalityVisual: profile.promptFragment)
        try write(output.data, named: "attempt-1-repair-raw.png", to: outputDirectory)
        log("usage     \(output.usage.dictionary)")
        let usageJSON = try JSONSerialization.data(
            withJSONObject: output.usage.dictionary, options: [.prettyPrinted, .sortedKeys])
        try write(usageJSON, named: "usage.json", to: outputDirectory)

        let repair = try ActionSheetProcessor.process(
            pngData: output.data, layout: ActionSheetLayout(rows: 2, columns: 2))
        try write(repair.pngData, named: "repair-m13-m16-strip.png", to: outputDirectory)
        let repairedMidpoints = try ActionSheetProcessor.replacingFrames(
            in: oldMidpoints, with: repair.pngData, at: [12, 13, 14, 15])
        try write(repairedMidpoints, named: "midpoint-strip-repaired.png", to: outputDirectory)
        let combined = try ActionSheetProcessor.interleaveStrips(
            keyframesPNG: keyframeStrip, inbetweensPNG: repairedMidpoints)
        try write(combined, named: "walk32-strip.png", to: outputDirectory)
        log("RESULT    repaired only M13...M16 and rebuilt 32 frames; not installed")
    }
}
