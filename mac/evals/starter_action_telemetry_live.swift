import Cocoa
import CryptoKit
import Foundation

private enum TelemetryLiveError: LocalizedError {
    case usage
    case invalidInput(String)
    case missingCredential
    case timedOut

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: starter_action_telemetry_live --pet-dir DIR --style-board PNG --style-profile human-v2|creature-v1 --output-root DIR --runtime-commit SHA [--quality medium|high] [--cohort-id ID] [--candidate-only true] [--retry-failed true] [--preflight true]"
        case .invalidInput(let value): return "invalid telemetry input: \(value)"
        case .missingCredential: return "OpenAI credential is not configured"
        case .timedOut: return "provider callback exceeded the telemetry wall-clock limit"
        }
    }
}

private struct Configuration {
    let petDirectory: URL
    let styleBoard: URL
    let styleProfile: MimoStyleProfile
    let outputRoot: URL
    let runtimeCommit: String
    let quality: PetFinalGenerationQuality
    let cohortID: String
    let candidateOnly: Bool
    let preflightOnly: Bool
    let retryFailed: Bool

    static func parse() throws -> Configuration {
        var values: [String: String] = [:]
        var index = 1
        while index < CommandLine.arguments.count {
            let key = CommandLine.arguments[index]
            guard key.hasPrefix("--"), index + 1 < CommandLine.arguments.count else {
                throw TelemetryLiveError.usage
            }
            values[key] = CommandLine.arguments[index + 1]
            index += 2
        }
        guard let pet = values["--pet-dir"],
              let style = values["--style-board"],
              let profileRaw = values["--style-profile"],
              let profile = MimoStyleProfile(rawValue: profileRaw),
              let output = values["--output-root"],
              let commit = values["--runtime-commit"],
              commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw TelemetryLiveError.usage
        }
        let cohortID = values["--cohort-id"] ?? String(commit.prefix(8))
        guard cohortID.range(
            of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            throw TelemetryLiveError.invalidInput("cohort id")
        }
        return Configuration(
            petDirectory: URL(fileURLWithPath: pet, isDirectory: true),
            styleBoard: URL(fileURLWithPath: style), styleProfile: profile,
            outputRoot: URL(fileURLWithPath: output, isDirectory: true),
            runtimeCommit: commit,
            quality: PetFinalGenerationQuality.resolve(values["--quality"]),
            cohortID: cohortID,
            candidateOnly: values["--candidate-only"] == "true",
            preflightOnly: values["--preflight"] == "true",
            retryFailed: values["--retry-failed"] == "true")
    }
}

private struct PreparedInput {
    let master: Data
    let styleBoard: Data
    let personality: String
    let inputFingerprint: String
    let contractFingerprint: String
}

private func sha256(_ values: [Data]) -> String {
    var hasher = SHA256()
    for value in values {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: value)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func prepare(_ configuration: Configuration) throws -> PreparedInput {
    let manifestURL = configuration.petDirectory.appendingPathComponent("manifest.json")
    guard let manifestData = try? Data(contentsOf: manifestURL),
          manifestData.count <= 64 * 1024,
          let manifest = try? JSONSerialization.jsonObject(with: manifestData)
            as? [String: Any],
          let asset = manifest["asset"] as? String,
          asset == URL(fileURLWithPath: asset).lastPathComponent,
          let temperament = manifest["temperamentID"] as? String else {
        throw TelemetryLiveError.invalidInput("manifest")
    }
    let sheetData = try Data(
        contentsOf: configuration.petDirectory.appendingPathComponent(asset),
        options: [.mappedIfSafe])
    let master = try CharacterSheetProcessor.extractNormalizedStage(
        fromNormalizedSheet: sheetData, stageIndex: 2)
    let fullStyle = try Data(contentsOf: configuration.styleBoard, options: [.mappedIfSafe])
    guard let styleBoard = MimoStyleReference.requestData(
        masterData: fullStyle, profile: configuration.styleProfile) else {
        throw TelemetryLiveError.invalidInput("style board")
    }
    let personality = CustomPetTemperaments.profile(for: temperament).promptFragment
    let promptData = StarterActionID.allCases.flatMap { action -> [Data] in
        let definition = StarterActionCatalog.definition(action)
        return definition.batches.indices.map { batch in
            Data(PetGenerationCoordinator.starterActionBatchPrompt(
                actionID: action, batchIndex: batch,
                personalityVisual: personality, hasStyleBoard: true,
                hasPreviousBatch: batch > 0).utf8)
        }
    }
    let inputFingerprint = sha256([
        master, styleBoard, Data(personality.utf8),
        Data(configuration.quality.rawValue.utf8),
    ])
    let contractFingerprint = sha256(promptData + [
        Data("gpt-image-2|1536x1024|\(configuration.quality.rawValue)|opaque|streaming-1".utf8),
    ])
    return PreparedInput(
        master: master, styleBoard: styleBoard, personality: personality,
        inputFingerprint: inputFingerprint,
        contractFingerprint: contractFingerprint)
}

private func estimatedCost(_ quality: PetFinalGenerationQuality) -> Double {
    quality == .high ? 0.169 : 0.045
}

private func safeError(_ error: Error) -> String {
    String(error.localizedDescription
        .replacingOccurrences(of: "\0", with: "").prefix(512))
}

private func write(_ evidence: DIYProviderTelemetryEvidence, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(evidence)
    try data.write(to: directory.appendingPathComponent("telemetry.json"), options: .atomic)
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: directory.appendingPathComponent("telemetry.json").path)
}

private func initialEvidence(role: DIYProviderTelemetryRole,
                             configuration: Configuration,
                             input: PreparedInput) -> DIYProviderTelemetryEvidence {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    return DIYProviderTelemetryEvidence(
        schemaVersion: DIYProviderTelemetryEvidence.schemaVersion,
        dataset: "mimo-diy-v3", role: role,
        cohortID: "\(role.rawValue)-\(configuration.cohortID)",
        runtimeCommit: configuration.runtimeCommit,
        contractFingerprint: input.contractFingerprint,
        inputFingerprint: input.inputFingerprint,
        quality: configuration.quality.rawValue, packCount: 1,
        createdAt: timestamp, updatedAt: timestamp, calls: [], actions: [])
}

private func loadOrCreate(role: DIYProviderTelemetryRole,
                          configuration: Configuration,
                          input: PreparedInput) throws
    -> (directory: URL, evidence: DIYProviderTelemetryEvidence) {
    let directory = configuration.outputRoot.appendingPathComponent(
        role.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("telemetry.json")
    if FileManager.default.fileExists(atPath: url.path) {
        let existing = try JSONDecoder().decode(
            DIYProviderTelemetryEvidence.self, from: Data(contentsOf: url))
        guard existing.role == role,
              existing.runtimeCommit == configuration.runtimeCommit,
              existing.contractFingerprint == input.contractFingerprint,
              existing.inputFingerprint == input.inputFingerprint,
              existing.quality == configuration.quality.rawValue else {
            throw TelemetryLiveError.invalidInput("checkpoint does not match this run")
        }
        return (directory, existing)
    }
    let evidence = initialEvidence(
        role: role, configuration: configuration, input: input)
    try write(evidence, to: directory)
    return (directory, evidence)
}

private func waitForBatch(coordinator: PetGenerationCoordinator,
                          action: StarterActionID,
                          batchIndex: Int,
                          master: Data,
                          previous: Data?,
                          styleBoard: Data,
                          personality: String,
                          quality: PetFinalGenerationQuality) throws
    -> (Result<PetGenerationOutput, Error>, Double) {
    let requestID = UUID().uuidString.lowercased()
    let started = Date()
    var result: Result<PetGenerationOutput, Error>?
    coordinator.generateStarterActionBatch(
        requestID: requestID, actionID: action, batchIndex: batchIndex,
        canonicalMasterData: master, previousBatchData: previous,
        styleBoardData: styleBoard, personalityVisual: personality,
        quality: quality,
        progress: { phase, _, _ in
            print("  \(action.rawValue) batch \(batchIndex + 1): \(phase)")
        },
        completion: { result = $0 })
    let deadline = Date().addingTimeInterval(960)
    while result == nil && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    guard let result else {
        coordinator.cancel(requestID)
        throw TelemetryLiveError.timedOut
    }
    return (result, Date().timeIntervalSince(started))
}

private func checkpointCall(role: DIYProviderTelemetryRole,
                            action: StarterActionID,
                            batchIndex: Int,
                            configuration: Configuration,
                            input: PreparedInput,
                            coordinator: PetGenerationCoordinator,
                            state: inout (directory: URL,
                                          evidence: DIYProviderTelemetryEvidence)) throws {
    if let existing = state.evidence.calls.firstIndex(where: {
        $0.actionID == action.rawValue && $0.batchIndex == batchIndex
    }) {
        if state.evidence.calls[existing].outcome == "success" { return }
        guard configuration.retryFailed else { return }
        state.evidence.calls.remove(at: existing)
    }
    let previousURL = batchIndex > 0
        ? state.directory.appendingPathComponent(
            "\(action.rawValue)-batch-\(String(format: "%02d", batchIndex)).png")
        : nil
    let previous = try previousURL.map { try Data(contentsOf: $0) }
    print("[\(role.rawValue)] \(action.rawValue) \(batchIndex + 1)/\(StarterActionCatalog.definition(action).estimatedProviderCalls)")
    let outcome: Result<PetGenerationOutput, Error>
    let seconds: Double
    let attemptedAt = Date()
    do {
        (outcome, seconds) = try waitForBatch(
            coordinator: coordinator, action: action, batchIndex: batchIndex,
            master: input.master, previous: previous,
            styleBoard: input.styleBoard, personality: input.personality,
            quality: configuration.quality)
    } catch {
        outcome = .failure(error)
        seconds = Date().timeIntervalSince(attemptedAt)
    }
    let filename = "\(action.rawValue)-batch-\(String(format: "%02d", batchIndex + 1)).png"
    let call: DIYProviderTelemetryCall
    switch outcome {
    case .success(let output):
        try output.data.write(
            to: state.directory.appendingPathComponent(filename), options: .atomic)
        call = DIYProviderTelemetryCall(
            actionID: action.rawValue, batchIndex: batchIndex,
            durationSeconds: seconds, outcome: "success",
            estimatedCostUSD: estimatedCost(configuration.quality),
            outputFilename: filename, usage: output.usage.dictionary, error: nil)
    case .failure(let error):
        let outcomeName: String
        if let generation = error as? PetGenerationError {
            switch generation {
            case .timedOut: outcomeName = "timed_out"
            case .cancelled: outcomeName = "cancelled"
            default: outcomeName = "failed"
            }
        } else {
            outcomeName = "failed"
        }
        call = DIYProviderTelemetryCall(
            actionID: action.rawValue, batchIndex: batchIndex,
            durationSeconds: seconds, outcome: outcomeName,
            estimatedCostUSD: estimatedCost(configuration.quality),
            outputFilename: nil, usage: nil, error: safeError(error))
    }
    state.evidence.calls.append(call)
    state.evidence.updatedAt = ISO8601DateFormatter().string(from: Date())
    try write(state.evidence, to: state.directory)
}

private func finishAction(_ action: StarterActionID,
                          state: inout (directory: URL,
                                        evidence: DIYProviderTelemetryEvidence)) throws {
    guard !state.evidence.actions.contains(where: { $0.actionID == action.rawValue })
    else { return }
    let definition = StarterActionCatalog.definition(action)
    do {
        let batches = try definition.batches.indices.map { index in
            try Data(contentsOf: state.directory.appendingPathComponent(
                "\(action.rawValue)-batch-\(String(format: "%02d", index + 1)).png"))
        }
        let processed = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: batches, keepCounts: definition.batches.map(\.keepCount))
        let filename = "\(action.rawValue)-strip.png"
        try processed.pngData.write(
            to: state.directory.appendingPathComponent(filename), options: .atomic)
        state.evidence.actions.append(DIYProviderTelemetryAction(
            actionID: action.rawValue, passed: true,
            stripFilename: filename, error: nil))
    } catch {
        state.evidence.actions.append(DIYProviderTelemetryAction(
            actionID: action.rawValue, passed: false,
            stripFilename: nil, error: safeError(error)))
    }
    state.evidence.updatedAt = ISO8601DateFormatter().string(from: Date())
    try write(state.evidence, to: state.directory)
}

@main
private struct StarterActionTelemetryLive {
    static func main() throws {
        let configuration = try Configuration.parse()
        let input = try prepare(configuration)
        guard let key = MimoSecret.openAI.read() else {
            throw TelemetryLiveError.missingCredential
        }
        print("preflight ok · credential \(MimoSecret.openAI.source.rawValue) · contract \(input.contractFingerprint.prefix(12))")
        if configuration.preflightOnly { return }

        let coordinator = PetGenerationCoordinator(openAIKeyReader: { key })
        if configuration.candidateOnly {
            var candidate = try loadOrCreate(
                role: .candidate, configuration: configuration, input: input)
            for action in StarterActionID.allCases {
                let definition = StarterActionCatalog.definition(action)
                for batch in definition.batches.indices {
                    try checkpointCall(
                        role: .candidate, action: action, batchIndex: batch,
                        configuration: configuration, input: input,
                        coordinator: coordinator, state: &candidate)
                }
                try finishAction(action, state: &candidate)
            }
            _ = try candidate.evidence.validated(
                expectedRole: .candidate, expectedDataset: "mimo-diy-v3")
            print("telemetry complete · candidate 10 calls · no assets installed")
            return
        }

        var baseline = try loadOrCreate(
            role: .baseline, configuration: configuration, input: input)
        var candidate = try loadOrCreate(
            role: .candidate, configuration: configuration, input: input)
        var pairIndex = 0
        for action in StarterActionID.allCases {
            let definition = StarterActionCatalog.definition(action)
            for batch in definition.batches.indices {
                if pairIndex.isMultiple(of: 2) {
                    try checkpointCall(
                        role: .baseline, action: action, batchIndex: batch,
                        configuration: configuration, input: input,
                        coordinator: coordinator, state: &baseline)
                    try checkpointCall(
                        role: .candidate, action: action, batchIndex: batch,
                        configuration: configuration, input: input,
                        coordinator: coordinator, state: &candidate)
                } else {
                    try checkpointCall(
                        role: .candidate, action: action, batchIndex: batch,
                        configuration: configuration, input: input,
                        coordinator: coordinator, state: &candidate)
                    try checkpointCall(
                        role: .baseline, action: action, batchIndex: batch,
                        configuration: configuration, input: input,
                        coordinator: coordinator, state: &baseline)
                }
                pairIndex += 1
            }
            try finishAction(action, state: &baseline)
            try finishAction(action, state: &candidate)
        }
        _ = try baseline.evidence.validated(
            expectedRole: .baseline, expectedDataset: "mimo-diy-v3")
        _ = try candidate.evidence.validated(
            expectedRole: .candidate, expectedDataset: "mimo-diy-v3")
        print("telemetry complete · baseline 10 calls · candidate 10 calls · no assets installed")
    }
}
