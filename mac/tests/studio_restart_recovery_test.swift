// sources: studio_recovery.swift generation_draft.swift studio_session.swift
import Foundation

enum MimoStyleProfile: String {
    case creatureV1 = "creature-v1"
    static func resolve(_ value: String?) -> Self { .creatureV1 }
}

enum PetFinalGenerationQuality: String {
    case medium
    static func resolve(_ value: String?) -> Self { .medium }
}

struct PendingCandidateBoardDraft {
    let pngData: Data; let candidatePNGs: [Data]; let sourceDataURI: String
    let referenceEvidenceJSON: String; let styleTuningNote: String
    let temperamentID: String; let likeness: Double
    let styleProfile: MimoStyleProfile; var lastTouchedAt: Date
}

struct PendingEvolutionSheetDraft {
    var pngData: Data; var stagePNGs: [Data]; let masterPNG: Data
    let sourceDataURI: String; let referenceEvidenceJSON: String
    var styleTuningNote: String; let temperamentID: String; let likeness: Double
    let styleProfile: MimoStyleProfile; let selectedCandidateIndex: Int
    let quality: PetFinalGenerationQuality; var stageQualities: [PetFinalGenerationQuality]
    var lastTouchedAt: Date; var relatedRequestIDs: [String]
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
    }
}

@main
struct StudioRestartRecoveryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-studio-restart-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestID = UUID().uuidString.lowercased()
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1])
        let source = "data:image/png;base64," + png.base64EncodedString()
        let recovery = StudioLocalRecoveryCheckpoint(
            requestID: requestID, kind: .candidates,
            sourceDataURI: source, referenceEvidenceJSON: "{}",
            styleTuningNote: "soft", temperamentID: "quiet-curious",
            likeness: 0.7, styleProfile: "creature-v1",
            providerSeconds: 8, usage: [:], styleBoardUsed: true,
            mode: "candidates", masterPNG: nil, draftFeedback: nil,
            selectedCandidateIndex: nil, quality: "low",
            candidateDraftID: nil, parentDraftID: nil, stage: nil,
            createdAt: Date())
        let drafts = FamiliarGenerationDraftStore(root: root)
        _ = try drafts.saveRaw(
            requestID: requestID, pngData: png, phase: .candidates,
            quality: "low", providerSeconds: 8, recovery: recovery)
        _ = try drafts.markLocalFailure(
            requestID: requestID, message: "near edge", localSeconds: 0.2)
        let sessions = FamiliarStudioSessionStore(root: root)
        try sessions.saveRecovery(recovery)

        let restartedDrafts = FamiliarGenerationDraftStore(root: root)
        let restartedSessions = FamiliarStudioSessionStore(root: root)
        let restoredRaw = try restartedDrafts.rawData(requestID: requestID)
        let restoredManifest = try restartedDrafts.manifest(requestID: requestID)
        let atomicRecovery = try restartedDrafts.recovery(requestID: requestID)
        expect(restoredRaw == png,
               "the paid raw output survives a fresh store instance")
        expect(restartedSessions.restoredRecovery()?.requestID == requestID
               && restartedSessions.runtimePayload()?["recoveryOperation"] as? String == "candidates",
               "the matching local recipe survives and remains actionable after restart")
        expect(atomicRecovery == recovery
               && restartedDrafts.recoverableRecoveryIDs() == [requestID],
               "raw output and its recipe commit atomically in one draft directory")
        expect(restoredManifest.status == .failedLocalProcessing,
               "restart recovery preserves the honest provider/local failure boundary")
        print("studio restart recovery tests passed")
    }
}
