// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func ordered(_ needles: [String], in source: String) -> Bool {
    var cursor = source.startIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: cursor..<source.endIndex) else {
            return false
        }
        cursor = range.upperBound
    }
    return true
}

@main
struct DIYNativePipelineTests {
    static func main() throws {
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)

        expect(!product.contains("PendingReferencePreflight") &&
               !product.contains("pendingReferencePreflights") &&
               !product.contains("case \"petConfirmReferences\""),
               "the native subject preflight must not stop on a confirmation bridge")
        expect(product.contains("self.pushPetReferenceAnalysis(result)") &&
               product.contains("partial: payload.identityBoard.png") &&
               ordered([
                    "private func prepareCandidateGeneration",
                    "self.startCandidateGeneration(",
                    "alreadyReserved: true",
               ], in: product),
               "Vision analysis must flow directly into the reserved Low request")
        expect(product.contains("body[\"likeness\"] as? Double ?? 0.70") &&
               product.contains("DIYStylePreset.resolve(body[\"stylePresetID\"] as? String)") &&
               product.contains("userTuning.isEmpty") &&
               product.contains("preset.tuningNote(language: voiceLanguage())"),
               "candidate generation must use the safe likeness and bounded preset fallback")

        expect(product.contains("let quality = PetFinalGenerationQuality.medium") &&
               product.contains("body[\"draftFeedback\"] as? String") &&
               product.contains("draftFeedback: draftFeedback") &&
               product.contains("petGenerator.generateFinalEvolutionSheet("),
               "final generation must be Medium and carry sanitized draft feedback")

        expect(main.contains("postInstallStarterActionCharacterID") &&
               main.contains("resumePostInstallStarterActions()") &&
               product.contains("queuePostInstallStarterActions(") &&
               ordered([
                    "private func queuePostInstallStarterActions(",
                    "startExpressionRun(",
                    "resumePostInstallStarterActions()",
               ], in: product) &&
               product.contains("private func endExpressionRun(continuePostInstallActions: Bool = true)") &&
               product.contains("self.endExpressionRun()") &&
               product.contains("startStarterActionPack(characterID: characterID, quality: .medium)"),
               "post-install work must serialize expressions before starter actions and survive watchdog handoff")
        expect(product.contains("mimo.postInstallStarterActionCharacterID.v1") &&
               product.contains("studioGenerationLedger.activeRequestID == nil") &&
               ordered([
                    "private func releaseStudioGeneration(_ requestID: String)",
                    "studioGenerationLedger.finish(requestID: requestID)",
                    "if self.starterActionPackCharacterID != nil",
                    "self.startNextStarterActionPackJob()",
                    "self.resumePostInstallStarterActions()",
               ], in: product),
               "the durable handoff must wait for and resume after the paid-generation ledger")
        expect(product.contains("job.state == .planned") &&
               product.contains("job.errorCode == \"generation_in_progress\"") &&
               product.contains("never replay them invisibly after launch"),
               "automatic restart must not replay provider-uncertain paid failures")
        expect(ordered([
                    "private func startNextStarterActionPackJob()",
                    "guard starterActionPackActiveJobID == nil else { return }",
                    "guard studioGenerationLedger.activeRequestID == nil else",
                    "let jobID = starterActionPackQueue.removeFirst()",
               ], in: product) &&
               product.contains("if self.starterActionPackCharacterID != nil") &&
               product.contains("self.startNextStarterActionPackJob()"),
               "a foreground Studio request must pause, not drain, the queued starter actions")

        expect(product.contains("private func installInternallyGeneratedStarterAction(") &&
               product.contains("origin\": \"mimo-internal-starter") &&
               ordered([
                    "try ActionSheetProcessor.processCoherentBatches(",
                    "try self.installInternallyGeneratedStarterAction(",
               ], in: product),
               "only processor-approved in-process starter sheets may auto-install")
        expect(product.contains("automaticInstallAllowed: false") &&
               product.contains("guard record.isEligibleForManualInstall else"),
               "external bundle metadata and manual Accept must remain fail-closed")
        expect(ordered([
                    "private func installInternallyGeneratedStarterAction(",
                    "let spec = try customPetStore.installActionStrip(",
                    "starterActionJobStore.markAwaitingReview(",
                    "starterActionJobStore.markInstalled(jobID: jobID)",
                    "emitStarterActionJob(installedStarter)",
               ], in: product),
               "internal install must persist the asset and mark both job stores before advancing")

        print("DIY native pipeline contract tests passed")
    }
}
