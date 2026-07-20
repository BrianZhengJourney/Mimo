// sources: pet_provider.swift custom_pet.swift character_sheet.swift reference_preprocessor.swift pet_generation.swift
// compile-only: paid end-to-end smoke test; not safe to run unattended
// Opt-in, paid end-to-end smoke test for Mimo's production familiar pipeline.
//
// This executable intentionally has no mock provider and no retry loop. It
// makes exactly three paid requests only when invoked with `--confirm-paid`:
// Low candidates, Medium evolution, and one Medium Seed replacement.

// Example (compile from the repository root):
// swiftc -O mac/custom_pet.swift mac/character_sheet.swift \
//   mac/reference_preprocessor.swift mac/pet_generation.swift \
//   mac/tests/live_generation_loop.swift -o /private/tmp/mimo-live-loop \
//   -framework Cocoa -framework WebKit -framework Security -framework ImageIO \
//   -framework Vision -framework CoreImage -framework CoreVideo
//
// Run:
// /private/tmp/mimo-live-loop --confirm-paid OUTPUT_DIR IMAGE1 IMAGE2 IMAGE3 IMAGE4 IMAGE5

// OPENAI_API_KEY may be set in the environment; otherwise MimoSecret reads the
// same login-keychain entry as the app. The key is never printed or persisted.


import AppKit
import CryptoKit
import Darwin
import Foundation

private enum LiveLoopError: LocalizedError {
    case usage
    case missingAPIKey
    case missingInput(String)
    case missingStyleBoard
    case preprocessingProducedNoPayload
    case generationTimedOut(String)
    case invalidCount(label: String, expected: Int, actual: Int)
    case invalidStageOrder([String])
    case untouchedStageChanged(String)
    case replacementDidNotChangeSeed
    case installVerification(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: live_generation_loop --confirm-paid OUTPUT_DIR IMAGE1 IMAGE2 IMAGE3 IMAGE4 IMAGE5"
        case .missingAPIKey:
            return "OpenAI API key is not configured in the environment or Mimo keychain."
        case .missingInput(let path):
            return "Reference image is missing or unreadable: \(path)"
        case .missingStyleBoard:
            return "Mimo style board was not found. Set MIMO_STYLE_BOARD_PATH to override its location."
        case .preprocessingProducedNoPayload:
            return "Local reference preprocessing produced no provider-safe payload."
        case .generationTimedOut(let phase):
            return "\(phase) did not complete within the harness deadline."
        case .invalidCount(let label, let expected, let actual):
            return "\(label) expected exactly \(expected) items, received \(actual)."
        case .invalidStageOrder(let stages):
            return "Evolution stage order was invalid: \(stages.joined(separator: ", "))."
        case .untouchedStageChanged(let stage):
            return "Local Seed replacement changed \(stage) RGBA bytes."
        case .replacementDidNotChangeSeed:
            return "Local replacement completed but Seed RGBA bytes did not change."
        case .installVerification(let detail):
            return "Temporary CustomPetStore verification failed: \(detail)"
        }
    }
}

private struct LiveLoopOptions {
    let outputDirectory: URL
    let imageURLs: [URL]

    static func parse() throws -> LiveLoopOptions {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 7, arguments.first == "--confirm-paid" else {
            throw LiveLoopError.usage
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
            .standardizedFileURL
        let images = arguments[2...].map {
            URL(fileURLWithPath: String($0), isDirectory: false).standardizedFileURL
        }
        guard images.count == 5 else { throw LiveLoopError.usage }
        return LiveLoopOptions(outputDirectory: output, imageURLs: images)
    }
}

private final class JSONLEmitter {
    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func emit(_ event: String, _ values: [String: Any] = [:]) {
        var object = values
        object["event"] = event
        object["elapsed_ms"] = milliseconds(since: startedAt)
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.sortedKeys]) else {
            return
        }
        lock.lock()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
        lock.unlock()
    }
}

private struct GenerationRun {
    let output: PetGenerationOutput
    let durationMilliseconds: Int
    let eventCounts: [String: Int]
    let partials: [[String: Int]]
}

private final class GenerationState {
    var result: Result<PetGenerationOutput, Error>?
    var eventCounts: [String: Int] = [:]
    var partials: [[String: Int]] = []
}

private typealias StagedStarter = (
    @escaping PetGenerationCoordinator.StagedProgress,
    @escaping PetGenerationCoordinator.StagedCompletion
) -> Void

@discardableResult
private func writeArtifact(_ data: Data, named name: String, to directory: URL,
                           emitter: JSONLEmitter) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try data.write(to: url, options: [.atomic])
    var values: [String: Any] = [
        "artifact": name,
        "bytes": data.count,
        "path": url.path,
        "sha256": sha256(data),
    ]
    if let dimensions = CharacterSheetProcessor.pngPixelDimensions(data) {
        values["width"] = dimensions.width
        values["height"] = dimensions.height
    }
    emitter.emit("artifact_written", values)
    return url
}

private func awaitGeneration(label: String, requestID: String,
                             timeout: TimeInterval,
                             emitter: JSONLEmitter,
                             cancel: @escaping () -> Void,
                             start: StagedStarter) throws -> GenerationRun {
    let state = GenerationState()
    let startedAt = ProcessInfo.processInfo.systemUptime
    emitter.emit("generation_started", [
        "phase": label,
        "request_id": requestID,
        "request_id_kind": "mimo-client",
    ])

    start({ phase, partialImage, partialIndex in
        state.eventCounts[phase, default: 0] += 1
        var values: [String: Any] = [
            "phase": label,
            "provider_phase": phase,
            "request_id": requestID,
        ]
        if let partialImage {
            let partial: [String: Int] = [
                "bytes": partialImage.count,
                "index": partialIndex ?? 0,
            ]
            state.partials.append(partial)
            values["partial_bytes"] = partialImage.count
            values["partial_index"] = partialIndex ?? 0
        }
        emitter.emit("generation_progress", values)
    }, { result in
        state.result = result
    })

    let deadline = Date(timeIntervalSinceNow: timeout)
    while state.result == nil && Date() < deadline {
        autoreleasepool {
            _ = RunLoop.current.run(mode: .default,
                                    before: min(deadline, Date(timeIntervalSinceNow: 0.1)))
        }
    }
    guard let result = state.result else {
        cancel()
        throw LiveLoopError.generationTimedOut(label)
    }

    let output = try result.get()
    let duration = milliseconds(since: startedAt)
    emitter.emit("generation_completed", [
        "bytes": output.data.count,
        "duration_ms": duration,
        "event_counts": state.eventCounts,
        "partial_events": state.partials,
        "phase": label,
        "request_id": requestID,
        "usage": output.usage.dictionary,
    ])
    return GenerationRun(output: output, durationMilliseconds: duration,
                         eventCounts: state.eventCounts, partials: state.partials)
}

private func styleBoardURL() throws -> URL {
    let fileManager = FileManager.default
    var candidates: [URL] = []
    if let override = ProcessInfo.processInfo.environment["MIMO_STYLE_BOARD_PATH"],
       !override.isEmpty {
        candidates.append(URL(fileURLWithPath: override).standardizedFileURL)
    }
    let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    candidates.append(current.appendingPathComponent(
        "mac/assets/style-reference/mimo-style-reference-board.png"))
    candidates.append(current.appendingPathComponent(
        "assets/style-reference/mimo-style-reference-board.png"))
    let macDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    candidates.append(macDirectory.appendingPathComponent(
        "assets/style-reference/mimo-style-reference-board.png"))

    guard let found = candidates.first(where: {
        fileManager.isReadableFile(atPath: $0.path)
    }) else { throw LiveLoopError.missingStyleBoard }
    return found
}

private func rgbaBytes(in image: CharacterSheetRGBAImage, stageIndex: Int) -> Data {
    let startX = stageIndex * CharacterSheetProcessor.outputStageSize
    let rowBytes = CharacterSheetProcessor.outputStageSize * 4
    var result = Data()
    result.reserveCapacity(rowBytes * image.height)
    for y in 0..<image.height {
        let offset = (y * image.width + startX) * 4
        result.append(contentsOf: image.pixels[offset..<(offset + rowBytes)])
    }
    return result
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func milliseconds(since start: TimeInterval) -> Int {
    Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
}

private func safeErrorMessage(_ error: Error) -> String {
    let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let scalars = raw.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
    }
    return String(String.UnicodeScalarView(scalars)).prefix(1_500).description
}

@main
struct MimoLiveGenerationLoop {
    static func main() {
        let emitter = JSONLEmitter()
        do {
            try run(emitter: emitter)
        } catch {
            emitter.emit("loop_failed", [
                "error": safeErrorMessage(error),
                "error_type": String(describing: type(of: error)),
            ])
            exit(EXIT_FAILURE)
        }
    }

    private static func run(emitter: JSONLEmitter) throws {
        let loopStartedAt = ProcessInfo.processInfo.systemUptime
        let options = try LiveLoopOptions.parse()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.outputDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        // Explicit preflight: this uses the same credential boundary as the
        // app and deliberately records only a boolean outcome.
        guard let openAIKey = MimoSecret.openAI.read() else {
            throw LiveLoopError.missingAPIKey
        }
        emitter.emit("credential_preflight", ["configured": true, "provider": "openai"])

        let inputData = try options.imageURLs.enumerated().map { index, url -> MimoReferenceInput in
            guard fileManager.isReadableFile(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                throw LiveLoopError.missingInput(url.path)
            }
            return MimoReferenceInput(id: "live-reference-\(index + 1)", data: data)
        }
        emitter.emit("preprocessing_started", [
            "input_count": inputData.count,
            "input_sizes": inputData.map { $0.data.count },
        ])
        let preprocessingStartedAt = ProcessInfo.processInfo.systemUptime
        let preprocessing = MimoReferencePreprocessor().process(inputData)
        let preprocessingDuration = milliseconds(since: preprocessingStartedAt)
        guard let payload = preprocessing.providerPayload else {
            throw LiveLoopError.preprocessingProducedNoPayload
        }
        _ = try writeArtifact(payload.identityBoard.png, named: "identity-board.png",
                              to: options.outputDirectory, emitter: emitter)
        emitter.emit("preprocessing_completed", [
            "board_mode": payload.identityBoard.mode.rawValue,
            "duration_ms": preprocessingDuration,
            "evidence_count": payload.identityBoard.referenceIDs.count,
            "image_count": preprocessing.images.count,
            "recommended_reference_count": preprocessing.recommendedReferences.count,
            "used_source_count": Set(payload.identityBoard.sourceInputIDs).count,
        ])

        let styleData = try Data(contentsOf: styleBoardURL(), options: [.mappedIfSafe])
        emitter.emit("style_board_loaded", [
            "bytes": styleData.count,
            "sha256": sha256(styleData),
        ])
        let sourceDataURI = PetGenerationCoordinator.dataURI(payload.identityBoard.png)
        let profile = CustomPetTemperaments.profile(for: "quiet-curious")
        let likeness = 0.65
        // Reuse the in-memory credential for all three phases so an ad-hoc
        // test binary can trigger at most one Keychain authorization prompt.
        // The value is neither logged nor persisted by the harness.
        let coordinator = PetGenerationCoordinator(openAIKeyReader: { openAIKey })

        let candidateRequestID = "live-candidates-\(UUID().uuidString.lowercased())"
        let candidateRun = try awaitGeneration(
            label: "low_candidates", requestID: candidateRequestID,
            timeout: 300, emitter: emitter,
            cancel: { coordinator.cancel(candidateRequestID) }
        ) { progress, completion in
            coordinator.generateCandidateBoard(
                requestID: candidateRequestID,
                sourceDataURI: sourceDataURI,
                styleBoardData: styleData,
                referenceEvidenceJSON: payload.analysisJSON,
                personalityVisual: profile.promptFragment,
                likeness: likeness,
                progress: progress,
                completion: completion)
        }
        _ = try writeArtifact(candidateRun.output.data, named: "candidate-board-raw.png",
                              to: options.outputDirectory, emitter: emitter)

        let candidateProcessingStartedAt = ProcessInfo.processInfo.systemUptime
        let candidates = try CharacterSheetProcessor.processCandidateBoard(
            pngData: candidateRun.output.data)
        guard candidates.candidatePNGs.count == 3 else {
            throw LiveLoopError.invalidCount(label: "candidate extraction", expected: 3,
                                             actual: candidates.candidatePNGs.count)
        }
        _ = try writeArtifact(candidates.pngData, named: "candidate-strip-normalized.png",
                              to: options.outputDirectory, emitter: emitter)
        for (index, candidate) in candidates.candidatePNGs.enumerated() {
            _ = try writeArtifact(candidate, named: "candidate-\(index).png",
                                  to: options.outputDirectory, emitter: emitter)
        }
        let master = candidates.candidatePNGs[0]
        emitter.emit("candidate_processing_completed", [
            "candidate_count": candidates.candidatePNGs.count,
            "duration_ms": milliseconds(since: candidateProcessingStartedAt),
            "selected_candidate_index": 0,
        ])

        let evolutionRequestID = "live-evolution-\(UUID().uuidString.lowercased())"
        let evolutionRun = try awaitGeneration(
            label: "medium_evolution", requestID: evolutionRequestID,
            timeout: 480, emitter: emitter,
            cancel: { coordinator.cancel(evolutionRequestID) }
        ) { progress, completion in
            coordinator.generateFinalEvolutionSheet(
                requestID: evolutionRequestID,
                masterData: master,
                sourceDataURI: sourceDataURI,
                styleBoardData: styleData,
                referenceEvidenceJSON: payload.analysisJSON,
                personalityVisual: profile.promptFragment,
                likeness: likeness,
                quality: .medium,
                progress: progress,
                completion: completion)
        }
        _ = try writeArtifact(evolutionRun.output.data, named: "evolution-raw.png",
                              to: options.outputDirectory, emitter: emitter)

        let evolutionProcessingStartedAt = ProcessInfo.processInfo.systemUptime
        let evolution = try CharacterSheetProcessor.process(pngData: evolutionRun.output.data)
        guard evolution.stages.count == 3 else {
            throw LiveLoopError.invalidCount(label: "evolution extraction", expected: 3,
                                             actual: evolution.stages.count)
        }
        let actualOrder = evolution.stages.map(\.kind.rawValue)
        guard actualOrder == CharacterSheetStageKind.allCases.map(\.rawValue) else {
            throw LiveLoopError.invalidStageOrder(actualOrder)
        }
        _ = try writeArtifact(evolution.pngData, named: "evolution-normalized.png",
                              to: options.outputDirectory, emitter: emitter)
        for stage in evolution.stages {
            _ = try writeArtifact(stage.pngData, named: "stage-\(stage.kind.rawValue).png",
                                  to: options.outputDirectory, emitter: emitter)
        }
        emitter.emit("evolution_processing_completed", [
            "duration_ms": milliseconds(since: evolutionProcessingStartedAt),
            "stage_count": evolution.stages.count,
            "stage_order": actualOrder,
        ])

        let replacementRequestID = "live-seed-replacement-\(UUID().uuidString.lowercased())"
        let replacementRun = try awaitGeneration(
            label: "medium_seed_replacement", requestID: replacementRequestID,
            timeout: 480, emitter: emitter,
            cancel: { coordinator.cancel(replacementRequestID) }
        ) { progress, completion in
            coordinator.regenerateEvolutionStage(
                requestID: replacementRequestID,
                stage: .seed,
                currentSheetData: evolution.pngData,
                masterData: master,
                sourceDataURI: sourceDataURI,
                styleBoardData: styleData,
                referenceEvidenceJSON: payload.analysisJSON,
                personalityVisual: profile.promptFragment,
                likeness: likeness,
                quality: .medium,
                progress: progress,
                completion: completion)
        }
        _ = try writeArtifact(replacementRun.output.data,
                              named: "seed-replacement-raw.png",
                              to: options.outputDirectory, emitter: emitter)

        let replacementProcessingStartedAt = ProcessInfo.processInfo.systemUptime
        let replacement = try CharacterSheetProcessor.processSingleStage(
            pngData: replacementRun.output.data, kind: .seed)
        _ = try writeArtifact(replacement.stage.pngData,
                              named: "seed-replacement-normalized.png",
                              to: options.outputDirectory, emitter: emitter)
        let replacedSheet = try CharacterSheetProcessor.replaceStage(
            in: evolution.pngData, kind: .seed,
            with: replacement.stage.pngData)
        _ = try writeArtifact(replacedSheet, named: "evolution-seed-replaced.png",
                              to: options.outputDirectory, emitter: emitter)

        let before = try CharacterSheetProcessor.decodePNG(evolution.pngData)
        let after = try CharacterSheetProcessor.decodePNG(replacedSheet)
        let seedBefore = rgbaBytes(in: before, stageIndex: 0)
        let bloomBefore = rgbaBytes(in: before, stageIndex: 1)
        let radiantBefore = rgbaBytes(in: before, stageIndex: 2)
        let seedAfter = rgbaBytes(in: after, stageIndex: 0)
        let bloomAfter = rgbaBytes(in: after, stageIndex: 1)
        let radiantAfter = rgbaBytes(in: after, stageIndex: 2)
        guard bloomBefore == bloomAfter else {
            throw LiveLoopError.untouchedStageChanged("Bloom")
        }
        guard radiantBefore == radiantAfter else {
            throw LiveLoopError.untouchedStageChanged("Radiant")
        }
        guard seedBefore != seedAfter else {
            throw LiveLoopError.replacementDidNotChangeSeed
        }
        emitter.emit("replacement_processing_completed", [
            "comparison": "rgba-bytes",
            "duration_ms": milliseconds(since: replacementProcessingStartedAt),
            "radiant_sha256_after": sha256(radiantAfter),
            "radiant_sha256_before": sha256(radiantBefore),
            "radiant_untouched_byte_identical": true,
            "bloom_sha256_after": sha256(bloomAfter),
            "bloom_sha256_before": sha256(bloomBefore),
            "bloom_untouched_byte_identical": true,
            "seed_changed": true,
        ])

        let installStartedAt = ProcessInfo.processInfo.systemUptime
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "mimo-live-loop-store-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot,
                                        withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let store = CustomPetStore(root: temporaryRoot)
        let installed = try store.install(
            pngData: replacedSheet,
            name: "Mimo Live Loop",
            temperamentID: profile.id,
            accent: profile.accent)
        guard let characterID = installed["characterID"] as? String else {
            throw LiveLoopError.installVerification("missing characterID")
        }
        let resolved = try store.runtimeSpec(characterID: characterID)
        guard resolved["characterID"] as? String == characterID else {
            throw LiveLoopError.installVerification("runtime lookup mismatch")
        }
        guard let assetValue = installed["assetURL"] as? String,
              let assetURL = URL(string: assetValue),
              try store.assetData(for: assetURL) == replacedSheet else {
            throw LiveLoopError.installVerification("installed asset bytes mismatch")
        }
        let listed = try store.listRuntimeSpecs()
        guard listed.count == 1 else {
            throw LiveLoopError.installVerification("expected one listed familiar")
        }
        emitter.emit("temporary_install_verified", [
            "asset_bytes": replacedSheet.count,
            "character_id": characterID,
            "duration_ms": milliseconds(since: installStartedAt),
            "listed_count": listed.count,
            "store_root": temporaryRoot.path,
        ])

        emitter.emit("loop_completed", [
            "candidate_request_id": candidateRequestID,
            "evolution_request_id": evolutionRequestID,
            "output_directory": options.outputDirectory.path,
            "replacement_request_id": replacementRequestID,
            "total_duration_ms": milliseconds(since: loopStartedAt),
            "paid_request_count": 3,
            "qualities": ["low", "medium", "medium"],
        ])
    }
}
