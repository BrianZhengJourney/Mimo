import Cocoa
import CryptoKit
import Foundation

private enum SleepSafeZoneLiveError: LocalizedError {
    case usage
    case invalidInput(String)
    case missingCredential
    case timedOut
    case targetFailed(Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: sleep_safe_zone_telemetry_live --pet-dir DIR "
                + "--style-board PNG --style-profile human-v2|creature-v1 "
                + "--output-root DIR --runtime-commit SHA "
                + "[--quality medium|high] [--retry-failed true] [--preflight true]"
        case .invalidInput(let value):
            return "invalid sleep telemetry input: \(value)"
        case .missingCredential:
            return "OpenAI credential is not configured"
        case .timedOut:
            return "provider callback exceeded the telemetry wall-clock limit"
        case .targetFailed(let count):
            return "sleep safe-zone target failed: \(count)/12 packs failed local QA"
        }
    }
}

private struct SleepSafeZoneConfiguration {
    let petDirectory: URL
    let styleBoard: URL
    let styleProfile: MimoStyleProfile
    let outputRoot: URL
    let runtimeCommit: String
    let quality: PetFinalGenerationQuality
    let preflightOnly: Bool
    let retryFailed: Bool

    static func parse() throws -> SleepSafeZoneConfiguration {
        var values: [String: String] = [:]
        var index = 1
        while index < CommandLine.arguments.count {
            let key = CommandLine.arguments[index]
            guard key.hasPrefix("--"), index + 1 < CommandLine.arguments.count else {
                throw SleepSafeZoneLiveError.usage
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
            throw SleepSafeZoneLiveError.usage
        }
        return SleepSafeZoneConfiguration(
            petDirectory: URL(fileURLWithPath: pet, isDirectory: true),
            styleBoard: URL(fileURLWithPath: style),
            styleProfile: profile,
            outputRoot: URL(fileURLWithPath: output, isDirectory: true),
            runtimeCommit: commit,
            quality: PetFinalGenerationQuality.resolve(values["--quality"]),
            preflightOnly: values["--preflight"] == "true",
            retryFailed: values["--retry-failed"] == "true")
    }
}

private struct SleepSafeZoneInput {
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

private func prepare(_ configuration: SleepSafeZoneConfiguration) throws
    -> SleepSafeZoneInput {
    let manifestURL = configuration.petDirectory.appendingPathComponent("manifest.json")
    guard let manifestData = try? Data(contentsOf: manifestURL),
          manifestData.count <= 64 * 1024,
          let manifest = try? JSONSerialization.jsonObject(with: manifestData)
            as? [String: Any],
          let asset = manifest["asset"] as? String,
          asset == URL(fileURLWithPath: asset).lastPathComponent,
          let temperament = manifest["temperamentID"] as? String else {
        throw SleepSafeZoneLiveError.invalidInput("manifest")
    }
    let sheetData = try Data(
        contentsOf: configuration.petDirectory.appendingPathComponent(asset),
        options: [.mappedIfSafe])
    let master = try CharacterSheetProcessor.extractNormalizedStage(
        fromNormalizedSheet: sheetData, stageIndex: 2)
    let fullStyle = try Data(contentsOf: configuration.styleBoard, options: [.mappedIfSafe])
    guard let styleBoard = MimoStyleReference.requestData(
        masterData: fullStyle, profile: configuration.styleProfile) else {
        throw SleepSafeZoneLiveError.invalidInput("style board")
    }
    let personality = CustomPetTemperaments.profile(for: temperament).promptFragment
    let definition = StarterActionCatalog.definition(.sleep)
    guard definition.contractRevision == DIYSleepSafeZoneEvidence.contractRevision,
          definition.batches.count == 2 else {
        throw SleepSafeZoneLiveError.invalidInput("sleep generation contract")
    }
    let prompts = definition.batches.indices.map { batch in
        Data(PetGenerationCoordinator.starterActionBatchPrompt(
            actionID: .sleep,
            batchIndex: batch,
            personalityVisual: personality,
            hasStyleBoard: true,
            hasPreviousBatch: batch > 0).utf8)
    }
    let inputFingerprint = sha256([
        master,
        styleBoard,
        Data(personality.utf8),
        Data(configuration.quality.rawValue.utf8),
    ])
    let contractFingerprint = sha256(prompts + [
        Data("gpt-image-2|1536x1024|\(configuration.quality.rawValue)|opaque|streaming-1".utf8),
    ])
    return SleepSafeZoneInput(
        master: master,
        styleBoard: styleBoard,
        personality: personality,
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

private func write(_ evidence: DIYSleepSafeZoneEvidence, to directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(evidence)
    let url = directory.appendingPathComponent("telemetry.json")
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func initialEvidence(configuration: SleepSafeZoneConfiguration,
                             input: SleepSafeZoneInput)
    -> DIYSleepSafeZoneEvidence {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    return DIYSleepSafeZoneEvidence(
        schemaVersion: DIYSleepSafeZoneEvidence.schemaVersion,
        dataset: DIYSleepSafeZoneEvidence.dataset,
        actionID: DIYSleepSafeZoneEvidence.actionID,
        contractRevision: DIYSleepSafeZoneEvidence.contractRevision,
        runtimeCommit: configuration.runtimeCommit,
        contractFingerprint: input.contractFingerprint,
        inputFingerprint: input.inputFingerprint,
        quality: configuration.quality.rawValue,
        packCount: DIYSleepSafeZoneEvidence.packCount,
        baselineEvidenceSHA256: DIYSleepSafeZoneEvidence.baselineEvidenceSHA256,
        historicalMixedFailures: 1,
        historicalMixedCount: 12,
        historicalSleepFailures: 1,
        historicalSleepCount: 3,
        createdAt: timestamp,
        updatedAt: timestamp,
        calls: [],
        results: [])
}

private func loadOrCreate(configuration: SleepSafeZoneConfiguration,
                          input: SleepSafeZoneInput) throws
    -> DIYSleepSafeZoneEvidence {
    try FileManager.default.createDirectory(
        at: configuration.outputRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let url = configuration.outputRoot.appendingPathComponent("telemetry.json")
    guard FileManager.default.fileExists(atPath: url.path) else {
        let evidence = initialEvidence(configuration: configuration, input: input)
        try write(evidence, to: configuration.outputRoot)
        return evidence
    }
    let evidence = try JSONDecoder().decode(
        DIYSleepSafeZoneEvidence.self, from: Data(contentsOf: url))
    guard evidence.runtimeCommit == configuration.runtimeCommit,
          evidence.contractFingerprint == input.contractFingerprint,
          evidence.inputFingerprint == input.inputFingerprint,
          evidence.quality == configuration.quality.rawValue else {
        throw SleepSafeZoneLiveError.invalidInput("checkpoint does not match this run")
    }
    return evidence
}

private func waitForBatch(coordinator: PetGenerationCoordinator,
                          batchIndex: Int,
                          input: SleepSafeZoneInput,
                          previous: Data?,
                          quality: PetFinalGenerationQuality) throws
    -> (Result<PetGenerationOutput, Error>, Double) {
    let requestID = UUID().uuidString.lowercased()
    let started = Date()
    var result: Result<PetGenerationOutput, Error>?
    coordinator.generateStarterActionBatch(
        requestID: requestID,
        actionID: .sleep,
        batchIndex: batchIndex,
        canonicalMasterData: input.master,
        previousBatchData: previous,
        styleBoardData: input.styleBoard,
        personalityVisual: input.personality,
        quality: quality,
        progress: { phase, _, _ in
            print("    sleep batch \(batchIndex + 1): \(phase)")
        },
        completion: { result = $0 })
    let deadline = Date().addingTimeInterval(960)
    while result == nil && Date() < deadline {
        _ = RunLoop.current.run(
            mode: .default, before: Date().addingTimeInterval(0.1))
    }
    guard let result else {
        coordinator.cancel(requestID)
        throw SleepSafeZoneLiveError.timedOut
    }
    return (result, Date().timeIntervalSince(started))
}

private func packDirectory(_ packIndex: Int,
                           configuration: SleepSafeZoneConfiguration) -> URL {
    configuration.outputRoot.appendingPathComponent(
        "pack-\(String(format: "%02d", packIndex + 1))", isDirectory: true)
}

private func relativeBatchFilename(packIndex: Int, batchIndex: Int) -> String {
    "pack-\(String(format: "%02d", packIndex + 1))/sleep-batch-"
        + "\(String(format: "%02d", batchIndex + 1)).png"
}

private func checkpointCall(packIndex: Int,
                            batchIndex: Int,
                            configuration: SleepSafeZoneConfiguration,
                            input: SleepSafeZoneInput,
                            coordinator: PetGenerationCoordinator,
                            evidence: inout DIYSleepSafeZoneEvidence) throws {
    if let existing = evidence.calls.firstIndex(where: {
        $0.packIndex == packIndex && $0.batchIndex == batchIndex
    }) {
        if evidence.calls[existing].outcome == "success" { return }
        guard configuration.retryFailed else { return }
        evidence.calls.remove(at: existing)
    }
    let directory = packDirectory(packIndex, configuration: configuration)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let previous = batchIndex > 0
        ? try Data(contentsOf: directory.appendingPathComponent("sleep-batch-01.png"))
        : nil
    print("[\(packIndex + 1)/\(DIYSleepSafeZoneEvidence.packCount)] batch \(batchIndex + 1)/2")
    let attemptedAt = Date()
    let outcome: Result<PetGenerationOutput, Error>
    let seconds: Double
    do {
        (outcome, seconds) = try waitForBatch(
            coordinator: coordinator,
            batchIndex: batchIndex,
            input: input,
            previous: previous,
            quality: configuration.quality)
    } catch {
        outcome = .failure(error)
        seconds = Date().timeIntervalSince(attemptedAt)
    }
    let relativeFilename = relativeBatchFilename(
        packIndex: packIndex, batchIndex: batchIndex)
    let call: DIYSleepSafeZoneCall
    switch outcome {
    case .success(let output):
        try output.data.write(
            to: configuration.outputRoot.appendingPathComponent(relativeFilename),
            options: .atomic)
        call = DIYSleepSafeZoneCall(
            packIndex: packIndex,
            batchIndex: batchIndex,
            durationSeconds: seconds,
            outcome: "success",
            estimatedCostUSD: estimatedCost(configuration.quality),
            outputFilename: relativeFilename,
            usage: output.usage.dictionary,
            error: nil)
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
        call = DIYSleepSafeZoneCall(
            packIndex: packIndex,
            batchIndex: batchIndex,
            durationSeconds: seconds,
            outcome: outcomeName,
            estimatedCostUSD: estimatedCost(configuration.quality),
            outputFilename: nil,
            usage: nil,
            error: safeError(error))
    }
    evidence.calls.append(call)
    evidence.updatedAt = ISO8601DateFormatter().string(from: Date())
    try write(evidence, to: configuration.outputRoot)
}

private func finishPack(_ packIndex: Int,
                        configuration: SleepSafeZoneConfiguration,
                        evidence: inout DIYSleepSafeZoneEvidence) throws {
    guard !evidence.results.contains(where: { $0.packIndex == packIndex }) else {
        return
    }
    let directory = packDirectory(packIndex, configuration: configuration)
    do {
        let batches = try (0..<2).map { batch in
            try Data(contentsOf: directory.appendingPathComponent(
                "sleep-batch-\(String(format: "%02d", batch + 1)).png"))
        }
        let definition = StarterActionCatalog.definition(.sleep)
        let processed = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: batches,
            keepCounts: definition.batches.map(\.keepCount))
        let relativeFilename = "pack-\(String(format: "%02d", packIndex + 1))/sleep-strip.png"
        try processed.pngData.write(
            to: configuration.outputRoot.appendingPathComponent(relativeFilename),
            options: .atomic)
        evidence.results.append(DIYSleepSafeZoneResult(
            packIndex: packIndex,
            passed: true,
            stripFilename: relativeFilename,
            error: nil))
    } catch {
        evidence.results.append(DIYSleepSafeZoneResult(
            packIndex: packIndex,
            passed: false,
            stripFilename: nil,
            error: safeError(error)))
    }
    evidence.updatedAt = ISO8601DateFormatter().string(from: Date())
    try write(evidence, to: configuration.outputRoot)
}

@main
private struct SleepSafeZoneTelemetryLive {
    static func main() throws {
        let configuration = try SleepSafeZoneConfiguration.parse()
        let input = try prepare(configuration)
        guard let key = MimoSecret.openAI.read() else {
            throw SleepSafeZoneLiveError.missingCredential
        }
        print("preflight ok · credential \(MimoSecret.openAI.source.rawValue)")
        print("input \(input.inputFingerprint)")
        print("contract \(input.contractFingerprint)")
        if configuration.preflightOnly { return }

        let coordinator = PetGenerationCoordinator(openAIKeyReader: { key })
        var evidence = try loadOrCreate(configuration: configuration, input: input)
        for pack in 0..<DIYSleepSafeZoneEvidence.packCount {
            for batch in 0..<2 {
                try checkpointCall(
                    packIndex: pack,
                    batchIndex: batch,
                    configuration: configuration,
                    input: input,
                    coordinator: coordinator,
                    evidence: &evidence)
            }
            try finishPack(
                pack, configuration: configuration, evidence: &evidence)
        }
        let summary = try evidence.validated()
        print("sleep telemetry complete · \(summary.callCount) calls · "
            + "\(summary.failedPackCount)/\(summary.sampleCount) failed QA · "
            + "~$\(String(format: "%.3f", summary.estimatedCostUSD))")
        guard summary.passesTarget else {
            throw SleepSafeZoneLiveError.targetFailed(summary.failedPackCount)
        }
        print("target passed · 0/12 sleep packs failed · no assets installed")
    }
}
