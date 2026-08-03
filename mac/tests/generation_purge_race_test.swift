// sources: generation_ledger.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func occurrences(_ needle: String, in source: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return source.components(separatedBy: needle).count - 1
}

private func section(_ source: String, from start: String, to end: String) -> String {
    guard let lower = source.range(of: start)?.lowerBound,
          let upper = source.range(of: end, range: lower..<source.endIndex)?.lowerBound else {
        return ""
    }
    return String(source[lower..<upper])
}

@main
struct GenerationPurgeRaceTests {
    static func main() throws {
        let main = try String(contentsOfFile: "mac/main.swift", encoding: .utf8)
        let product = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)
        let settings = try String(contentsOfFile: "mac/settings.html", encoding: .utf8)

        let queuedBeforeErase = StudioPrivacyGeneration.token(for: 12)
        expect(StudioPrivacyGeneration.accepts(queuedBeforeErase, currentEpoch: 12),
               "the settings generation visible before erase is accepted normally")
        expect(!StudioPrivacyGeneration.accepts(queuedBeforeErase, currentEpoch: 13),
               "a start message queued before erase is rejected after the epoch advances")
        expect(!StudioPrivacyGeneration.accepts(nil, currentEpoch: 13),
               "missing privacy tokens fail closed")

        expect(main.contains("var activeStudioDraftRequestID: String?")
               && main.contains("var generationPurgeEpoch: UInt64 = 0"),
               "AppDelegate must track the draft-producing request and privacy epoch")

        let purge = section(
            product,
            from: "private func purgeUnadoptedGenerationStateForErase() -> Bool",
            to: "private func reserveProviderGeneration")
        expect(!purge.isEmpty, "Delete Everything needs one generation purge boundary")
        for operation in [
            "generationPurgeEpoch &+= 1",
            "petReferenceImportQueue = nil",
            "settingsCall(\"petPrivacyReset\"",
            "activeStudioDraftRequestID = nil",
            "activeStudioCancellationToken?.cancel()",
            "studioGenerationLedger.finish(requestID: studioRequestID)",
            "petGenerator.cancel(studioRequestID)",
            "expressionRunWatchdog?.cancel()",
            "expressionRunRequestID = nil",
            "expressionRunCharacterID = nil",
            "petGenerator.cancel(expressionRequestID)",
            "activeStageParents.removeAll",
            "pendingCandidateBoards.removeAll",
            "pendingEvolutionSheets.removeAll",
            "pendingLocalRecoveries.removeAll",
            "generationDraftStore.purgeAll()",
        ] {
            expect(purge.contains(operation), "purge boundary must perform \(operation)")
        }
        expect(!purge.contains("customPetStore.delete")
               && !purge.contains("deletePetLibraryCharacter"),
               "privacy purge must preserve adopted familiar assets")

        guard let fence = product.range(
                of: "let generationCleared = purgeUnadoptedGenerationStateForErase()"),
              let erase = product.range(of: "eraseAllHistory()",
                                        range: fence.lowerBound..<product.endIndex) else {
            expect(false, "Delete Everything must call the generation purge")
            return
        }
        expect(fence.lowerBound < erase.lowerBound,
               "generation producers must be invalidated before files are erased")
        expect(product.contains("if !generationCleared { erased = false }"),
               "a failed draft purge must surface as an incomplete erase")

        for type in [
            "petUpload", "petGenerateCandidates", "petGenerateEvolution",
            "petRegenerateStage", "petRetryLocalProcessing",
            "petContinueInBackground", "petInstallRaster",
            "petRegenerateExpressions",
        ] {
            expect(product.contains("\"\(type)\""),
                   "native privacy scope must include \(type)")
        }
        expect(product.contains("Self.studioPrivacyScopedSettingsTypes.contains(type)")
               && product.contains("!acceptsStudioPrivacyGeneration(body)"),
               "every privacy-scoped settings start must pass the native token fence")
        expect(product.contains("\"studioPrivacyGeneration\": studioPrivacyGenerationToken"),
               "settings state must receive the current native privacy token")

        let reset = section(settings, from: "function petPrivacyReset(event)",
                            to: "function selectTemperament")
        expect(!reset.isEmpty, "settings needs one complete Studio privacy reset")
        for operation in [
            "clearTimeout(candidateAutoGenerateTimer)",
            "candidateAutoGenerateSignature=''",
            "petReferenceLoadQueue=Promise.resolve()",
            "source:null", "references:[]", "candidates:[]", "sheet:null",
            "partialImage:null", "rawPreview:null", "closeCandidateLightbox()",
        ] {
            expect(reset.contains(operation),
                   "settings privacy reset must perform \(operation)")
        }
        for type in [
            "petUpload", "petGenerateCandidates", "petGenerateEvolution",
            "petRetryLocalProcessing", "petContinueInBackground",
            "petInstallRaster", "petRegenerateExpressions",
        ] {
            expect(settings.contains("sendStudio({type:'\(type)'"),
                   "settings must bind \(type) to its visible privacy token")
        }
        expect(settings.contains("privacyGeneration!==studioPrivacyGeneration")
               && settings.contains("isCurrentStudioPrivacyEvent(event)"),
               "late local/native photo imports must not refill a reset reference set")

        expect(product.contains("activeStudioDraftRequestID = requestID")
               && product.contains("if activeStudioDraftRequestID == requestID"),
               "draft request ownership must be acquired and released explicitly")
        expect(occurrences("studioGenerationIsCurrent(", in: product) >= 11,
               "candidate, evolution, stage provider/local callbacks need epoch guards")
        expect(occurrences("expressionGenerationIsCurrent(", in: product) >= 5,
               "expression provider and local callbacks need request+epoch guards")
        expect(occurrences("retainRaw(", in: product) == 5
               && occurrences("generationDraftStore.saveRaw", in: product) == 1,
               "all draft writes must pass through the fenced retainRaw boundary")
        expect(occurrences("purgeEpoch: purgeEpoch)", in: product) >= 4,
               "every retainRaw caller must carry its captured purge epoch")

        print("generation purge race tests passed")
    }
}
