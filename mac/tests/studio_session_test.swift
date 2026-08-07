// sources: studio_recovery.swift studio_session.swift
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
    let pngData: Data
    let candidatePNGs: [Data]
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    let styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    let styleProfile: MimoStyleProfile
    var lastTouchedAt: Date
}

struct PendingEvolutionSheetDraft {
    var pngData: Data
    var stagePNGs: [Data]
    let masterPNG: Data
    let sourceDataURI: String
    let referenceEvidenceJSON: String
    var styleTuningNote: String
    let temperamentID: String
    let likeness: Double
    let styleProfile: MimoStyleProfile
    let selectedCandidateIndex: Int
    let quality: PetFinalGenerationQuality
    var stageQualities: [PetFinalGenerationQuality]
    var lastTouchedAt: Date
    var relatedRequestIDs: [String]
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct StudioSessionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mimo-studio-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FamiliarStudioSessionStore(root: root)
        let requestID = UUID().uuidString.lowercased()
        let image = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let source = "data:image/png;base64," + image.base64EncodedString()

        try store.updateUI([
            "name": "Lulu", "primaryReferenceID": "ref-1",
            "references": [["id": "ref-1", "name": "source.png",
                            "source": source, "width": 32, "height": 48]],
            "temperamentID": "quiet-curious", "stylePresetID": "mimo-v2",
            "styleTuningNote": "soft", "styleTuningCustomized": true,
            "candidateIndex": 1, "candidateFeedback": ["1": "small smile"],
            "status": "busy", "operation": "candidates", "requestID": requestID,
        ])
        try store.saveCandidate(id: requestID, value: .init(
            pngData: image, candidatePNGs: [image, image, image],
            sourceDataURI: source, referenceEvidenceJSON: "{}",
            styleTuningNote: "soft", temperamentID: "quiet-curious",
            likeness: 0.7, styleProfile: .creatureV1, lastTouchedAt: Date()))

        let restoredStore = FamiliarStudioSessionStore(root: root)
        let payload = restoredStore.runtimePayload()
        expect(payload?["name"] as? String == "Lulu"
               && payload?["interrupted"] as? Bool == true
               && (payload?["references"] as? [[String: Any]])?.count == 1
               && (payload?["candidates"] as? [String])?.count == 3,
               "UI state, references, and successful candidates survive a fresh store instance")
        expect(restoredStore.restoredCandidate()?.0 == requestID,
               "the native pending candidate can be rehydrated after restart")

        let evolutionID = UUID().uuidString.lowercased()
        try restoredStore.saveEvolution(id: evolutionID, value: .init(
            pngData: image, stagePNGs: [image, image, image], masterPNG: image,
            sourceDataURI: source, referenceEvidenceJSON: "{}",
            styleTuningNote: "soft", temperamentID: "quiet-curious",
            likeness: 0.7, styleProfile: .creatureV1, selectedCandidateIndex: 1,
            quality: .medium, stageQualities: [.medium, .medium, .medium],
            lastTouchedAt: Date(), relatedRequestIDs: [requestID, evolutionID]))
        expect(FamiliarStudioSessionStore(root: root).restoredEvolution()?.0 == evolutionID,
               "the paid final and its stages survive restart")

        let sessionURL = root.appendingPathComponent("StudioSession/session.plist")
        var legacy = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: sessionURL), options: [], format: nil) as! [String: Any]
        legacy["schemaVersion"] = 1
        try PropertyListSerialization.data(
            fromPropertyList: legacy, format: .binary, options: 0).write(
                to: sessionURL, options: .atomic)
        expect(FamiliarStudioSessionStore(root: root).restoredEvolution()?.0 == evolutionID,
               "schema-v1 sessions remain readable after the restart-recovery upgrade")

        let recoveryID = UUID().uuidString.lowercased()
        let recovery = StudioLocalRecoveryCheckpoint(
            requestID: recoveryID, kind: .evolution,
            sourceDataURI: source, referenceEvidenceJSON: "{}",
            styleTuningNote: "quiet", temperamentID: "quiet-curious",
            likeness: 0.7, styleProfile: "creature-v1",
            providerSeconds: 12, usage: ["totalTokens": 42],
            styleBoardUsed: true, mode: nil, masterPNG: image,
            draftFeedback: "smaller ears", selectedCandidateIndex: 1,
            quality: "medium", candidateDraftID: requestID,
            parentDraftID: nil, stage: nil, createdAt: Date())
        try restoredStore.saveRecovery(recovery)
        let restartedRecovery = FamiliarStudioSessionStore(root: root).restoredRecovery()
        expect(restartedRecovery == recovery
               && FamiliarStudioSessionStore(root: root).runtimePayload()?["recoveryRequestID"] as? String == recoveryID,
               "the no-spend local-processing recipe survives restart beside the raw draft")
        try restoredStore.clearRecovery(requestID: recoveryID)
        expect(FamiliarStudioSessionStore(root: root).restoredRecovery() == nil,
               "a completed or explicitly discarded recovery recipe clears atomically")

        let attributes = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
               "the durable Studio checkpoint is private to the current user")

        try restoredStore.purgeAll()
        expect(restoredStore.runtimePayload() == nil,
               "Forget Everything removes the durable Studio session")
        print("studio session tests passed")
    }
}
