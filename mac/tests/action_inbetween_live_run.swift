// sources: starter_action.swift pet_provider.swift custom_pet.swift character_sheet.swift action_sheet.swift studio_recovery.swift generation_draft.swift generation_ledger.swift style_reference.swift reference_preprocessor.swift pet_generation.swift
// compile-only: one paid OpenAI walk-inbetween generation; opt-in only
// Run from the repository root after `./mac/test.sh action_inbetween`:
//   action_inbetween_live_run --confirm-paid OUTPUT_DIR PET_SHEET KEYFRAME_RAW KEYFRAME_STRIP

import AppKit
import Foundation

private enum InbetweenRunError: LocalizedError {
    case usage
    case missingAPIKey
    case missingInput(String)
    case timedOut
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: action_inbetween_live_run --confirm-paid OUTPUT_DIR PET_SHEET KEYFRAME_RAW KEYFRAME_STRIP"
        case .missingAPIKey: return "OpenAI API key is not configured."
        case .missingInput(let path): return "Input is missing or unreadable: \(path)"
        case .timedOut: return "Generation did not finish before the 8-minute deadline."
        case .generationFailed(let message): return "Generation failed: \(message)"
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@discardableResult
private func write(_ data: Data, named name: String, to directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    log("artifact  \(name)  \(data.count) bytes")
    return url
}

private func input(_ path: String) throws -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
        throw InbetweenRunError.missingInput(path)
    }
    return data
}

private func awaitMidpoints(coordinator: PetGenerationCoordinator,
                            stageFrame: Data, keyframeSheet: Data,
                            motionGuide: Data, styleBoard: Data?,
                            personalityVisual: String) throws -> PetGenerationOutput {
    let requestID = "walk-midpoints-live-\(UUID().uuidString.lowercased())"
    let startedAt = Date()
    var outcome: Result<PetGenerationOutput, Error>?
    coordinator.generateWalkInbetweenSheet(
        requestID: requestID, stage: .radiant,
        stageFrameData: stageFrame, keyframeSheetData: keyframeSheet,
        motionGuideData: motionGuide, styleBoardData: styleBoard,
        personalityVisual: personalityVisual, quality: .medium,
        progress: { phase, _, _ in
            log("phase     \(phase)  +\(Int(Date().timeIntervalSince(startedAt)))s")
        }, completion: { outcome = $0 })
    let deadline = Date(timeIntervalSinceNow: 480)
    while outcome == nil && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default,
                                    before: min(deadline, Date(timeIntervalSinceNow: 0.1)))
        }
    }
    switch outcome {
    case .success(let output): return output
    case .failure(let error): throw InbetweenRunError.generationFailed("\(error)")
    case nil:
        coordinator.cancel(requestID)
        throw InbetweenRunError.timedOut
    }
}

@main
struct ActionInbetweenLiveRun {
    static func main() {
        do { try run() } catch {
            log("FAILED    \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(EXIT_FAILURE)
        }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 6, arguments[1] == "--confirm-paid" else {
            throw InbetweenRunError.usage
        }
        let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let petSheet = try input(arguments[3])
        let keyframeSheet = try input(arguments[4])
        let keyframeStrip = try input(arguments[5])
        guard let key = MimoSecret.openAI.read() else { throw InbetweenRunError.missingAPIKey }

        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stageFrame = try CharacterSheetProcessor.extractNormalizedStage(
            fromNormalizedSheet: petSheet, stageIndex: 2)
        try write(stageFrame, named: "reference-mature-frame.png", to: outputDirectory)

        let motionGuidePath = "mac/assets/motion-reference/biped-walk-inbetweens-16.png"
        let motionGuide = try input(motionGuidePath)
        let styleMasterPath = "mac/assets/style-reference/mimo-style-reference-board.png"
        let styleMaster = try? input(styleMasterPath)
        let styleBoard = styleMaster.flatMap(MimoStyleReference.requestData(masterData:))
        log("preflight  1 paid call; 16 midpoint poses; medium; 2048x2048")
        log("references stage=\(stageFrame.count) keyframes=\(keyframeSheet.count) "
            + "guide=\(motionGuide.count) style=\(styleBoard?.count ?? 0) bytes")

        let profile = CustomPetTemperaments.profile(for: "quiet-curious")
        let coordinator = PetGenerationCoordinator(openAIKeyReader: { key })
        let output = try awaitMidpoints(
            coordinator: coordinator, stageFrame: stageFrame,
            keyframeSheet: keyframeSheet, motionGuide: motionGuide,
            styleBoard: styleBoard, personalityVisual: profile.promptFragment)
        try write(output.data, named: "attempt-1-midpoints-raw.png", to: outputDirectory)
        log("usage     \(output.usage.dictionary)")
        let usageJSON = try JSONSerialization.data(
            withJSONObject: output.usage.dictionary, options: [.prettyPrinted, .sortedKeys])
        try write(usageJSON, named: "usage.json", to: outputDirectory)

        let midpoints = try ActionSheetProcessor.process(pngData: output.data,
                                                         layout: .fourByFour)
        try write(midpoints.pngData, named: "midpoint-strip.png", to: outputDirectory)
        let combined = try ActionSheetProcessor.interleaveStrips(
            keyframesPNG: keyframeStrip, inbetweensPNG: midpoints.pngData)
        try write(combined, named: "walk32-strip.png", to: outputDirectory)

        let keyDecoded = try CharacterSheetProcessor.decodePNG(keyframeStrip)
        let midpointDecoded = try CharacterSheetProcessor.decodePNG(midpoints.pngData)
        func heights(_ strip: CharacterSheetRGBAImage) -> [Int] {
            (0..<16).compactMap { index in
                let frame = ActionSheetProcessor.crop(
                    strip, x: index * strip.height, y: 0,
                    width: strip.height, height: strip.height)
                return CharacterSheetProcessor.alphaBounds(of: frame)?.height
            }
        }
        let keyHeights = heights(keyDecoded)
        let midpointHeights = heights(midpointDecoded)
        log("heights   K \(keyHeights)")
        log("heights   M \(midpointHeights)")
        log("RESULT    generated one 16-midpoint pass and interleaved 32 frames; not installed")
    }
}
