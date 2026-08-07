// Mimo Studio — durable, local-only working session.
//
// Reference images and successful paid outputs survive an app restart. An
// in-flight provider request is recorded but never silently replayed: the
// restored UI marks it interrupted and lets the user decide what to do next.

import Foundation

private struct StoredStudioReference: Codable {
    var id: String
    var name: String
    var mimeType: String
    var data: Data
    var width: Int?
    var height: Int?
}

private struct StoredStudioUI: Codable {
    var name: String = ""
    var primaryReferenceID: String?
    var references: [StoredStudioReference] = []
    var temperamentID: String = "quiet-curious"
    var stylePresetID: String = "mimo-v2"
    var styleTuningNote: String = ""
    var styleTuningCustomized = false
    var candidateIndex: Int?
    var candidateFeedback: [String: String] = [:]
    var status: String = "idle"
    var operation: String?
    var requestID: String?
    var updatedAt = Date()
}

private struct StoredCandidateDraft: Codable {
    var id: String
    var pngData: Data
    var candidatePNGs: [Data]
    var sourceDataURI: String
    var referenceEvidenceJSON: String
    var styleTuningNote: String
    var temperamentID: String
    var likeness: Double
    var styleProfile: String
    var lastTouchedAt: Date
}

private struct StoredEvolutionDraft: Codable {
    var id: String
    var pngData: Data
    var stagePNGs: [Data]
    var masterPNG: Data
    var sourceDataURI: String
    var referenceEvidenceJSON: String
    var styleTuningNote: String
    var temperamentID: String
    var likeness: Double
    var styleProfile: String
    var selectedCandidateIndex: Int
    var quality: String
    var stageQualities: [String]
    var lastTouchedAt: Date
    var relatedRequestIDs: [String]
}

private struct FamiliarStudioEnvelope: Codable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var ui: StoredStudioUI?
    var candidate: StoredCandidateDraft?
    var evolution: StoredEvolutionDraft?
}

final class FamiliarStudioSessionStore {
    static let folderName = "StudioSession"
    static let filename = "session.plist"
    static let maximumReferenceBytes = 20 * 1024 * 1024
    static let maximumReferenceSetBytes = 80 * 1024 * 1024

    private let fileManager: FileManager
    private let folderURL: URL
    private let fileURL: URL
    private let lock = NSLock()

    init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        folderURL = root.standardizedFileURL.appendingPathComponent(
            Self.folderName, isDirectory: true)
        fileURL = folderURL.appendingPathComponent(Self.filename)
    }

    func updateUI(_ object: [String: Any]) throws {
        let references = try Self.references(from: object["references"])
        let feedback = (object["candidateFeedback"] as? [String: Any])?.reduce(
            into: [String: String]()) { output, pair in
                if let value = pair.value as? String {
                    output[pair.key] = String(value.prefix(160))
                }
            } ?? [:]
        var ui = StoredStudioUI()
        ui.name = String((object["name"] as? String ?? "").prefix(28))
        ui.primaryReferenceID = object["primaryReferenceID"] as? String
        ui.references = references
        ui.temperamentID = String((object["temperamentID"] as? String
            ?? "quiet-curious").prefix(40))
        ui.stylePresetID = String((object["stylePresetID"] as? String
            ?? "mimo-v2").prefix(40))
        ui.styleTuningNote = String((object["styleTuningNote"] as? String
            ?? "").prefix(160))
        ui.styleTuningCustomized = object["styleTuningCustomized"] as? Bool ?? false
        ui.candidateIndex = (object["candidateIndex"] as? NSNumber)?.intValue
        ui.candidateFeedback = feedback
        ui.status = String((object["status"] as? String ?? "idle").prefix(30))
        ui.operation = (object["operation"] as? String).map { String($0.prefix(30)) }
        ui.requestID = (object["requestID"] as? String).flatMap {
            UUID(uuidString: $0)?.uuidString.lowercased()
        }
        ui.updatedAt = Date()
        try update { $0.ui = ui }
    }

    func saveCandidate(id: String, value: PendingCandidateBoardDraft) throws {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let stored = StoredCandidateDraft(
            id: id, pngData: value.pngData, candidatePNGs: value.candidatePNGs,
            sourceDataURI: value.sourceDataURI,
            referenceEvidenceJSON: value.referenceEvidenceJSON,
            styleTuningNote: value.styleTuningNote,
            temperamentID: value.temperamentID, likeness: value.likeness,
            styleProfile: value.styleProfile.rawValue,
            lastTouchedAt: value.lastTouchedAt)
        try update { envelope in
            envelope.candidate = stored
            // A new candidate branch supersedes an older unadopted final.
            envelope.evolution = nil
        }
    }

    func saveEvolution(id: String, value: PendingEvolutionSheetDraft) throws {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let stored = StoredEvolutionDraft(
            id: id, pngData: value.pngData, stagePNGs: value.stagePNGs,
            masterPNG: value.masterPNG, sourceDataURI: value.sourceDataURI,
            referenceEvidenceJSON: value.referenceEvidenceJSON,
            styleTuningNote: value.styleTuningNote,
            temperamentID: value.temperamentID, likeness: value.likeness,
            styleProfile: value.styleProfile.rawValue,
            selectedCandidateIndex: value.selectedCandidateIndex,
            quality: value.quality.rawValue,
            stageQualities: value.stageQualities.map(\.rawValue),
            lastTouchedAt: value.lastTouchedAt,
            relatedRequestIDs: value.relatedRequestIDs)
        try update { $0.evolution = stored }
    }

    func restoredCandidate() -> (String, PendingCandidateBoardDraft)? {
        guard let value = load()?.candidate else { return nil }
        return (value.id, PendingCandidateBoardDraft(
            pngData: value.pngData, candidatePNGs: value.candidatePNGs,
            sourceDataURI: value.sourceDataURI,
            referenceEvidenceJSON: value.referenceEvidenceJSON,
            styleTuningNote: value.styleTuningNote,
            temperamentID: value.temperamentID, likeness: value.likeness,
            styleProfile: MimoStyleProfile.resolve(value.styleProfile),
            lastTouchedAt: Date()))
    }

    var persistedCandidateID: String? { load()?.candidate?.id }
    var persistedEvolutionID: String? { load()?.evolution?.id }

    func restoredEvolution() -> (String, PendingEvolutionSheetDraft)? {
        guard let value = load()?.evolution else { return nil }
        let quality = PetFinalGenerationQuality.resolve(value.quality)
        return (value.id, PendingEvolutionSheetDraft(
            pngData: value.pngData, stagePNGs: value.stagePNGs,
            masterPNG: value.masterPNG, sourceDataURI: value.sourceDataURI,
            referenceEvidenceJSON: value.referenceEvidenceJSON,
            styleTuningNote: value.styleTuningNote,
            temperamentID: value.temperamentID, likeness: value.likeness,
            styleProfile: MimoStyleProfile.resolve(value.styleProfile),
            selectedCandidateIndex: value.selectedCandidateIndex,
            quality: quality,
            stageQualities: value.stageQualities.map {
                PetFinalGenerationQuality.resolve($0)
            },
            lastTouchedAt: Date(), relatedRequestIDs: value.relatedRequestIDs))
    }

    func runtimePayload() -> [String: Any]? {
        guard let envelope = load(), envelope.ui != nil
                || envelope.candidate != nil || envelope.evolution != nil else { return nil }
        var output: [String: Any] = [:]
        if let ui = envelope.ui {
            output["name"] = ui.name
            output["primaryReferenceID"] = ui.primaryReferenceID ?? ""
            output["references"] = ui.references.map { reference in
                var row: [String: Any] = [
                    "id": reference.id, "name": reference.name,
                    "source": Self.dataURI(reference.data, mimeType: reference.mimeType),
                ]
                if let width = reference.width { row["width"] = width }
                if let height = reference.height { row["height"] = height }
                return row
            }
            output["temperamentID"] = ui.temperamentID
            output["stylePresetID"] = ui.stylePresetID
            output["styleTuningNote"] = ui.styleTuningNote
            output["styleTuningCustomized"] = ui.styleTuningCustomized
            if let index = ui.candidateIndex { output["candidateIndex"] = index }
            output["candidateFeedback"] = ui.candidateFeedback
            output["interrupted"] = ui.status == "busy" || ui.status == "installing"
            output["operation"] = ui.operation ?? ""
        }
        if let candidate = envelope.candidate {
            output["candidateDraftID"] = candidate.id
            output["candidates"] = candidate.candidatePNGs.map {
                Self.dataURI($0, mimeType: "image/png")
            }
        }
        if let evolution = envelope.evolution {
            output["draftID"] = evolution.id
            output["sheet"] = Self.dataURI(evolution.pngData, mimeType: "image/png")
            output["sheetQuality"] = evolution.quality
            output["stageQualities"] = evolution.stageQualities
        }
        return output
    }

    func purgeAll() throws {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: folderURL.path) else { return }
        try fileManager.removeItem(at: folderURL)
    }

    private func update(_ mutate: (inout FamiliarStudioEnvelope) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var envelope = loadUnlocked() ?? FamiliarStudioEnvelope()
        mutate(&envelope)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(envelope).write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: fileURL.path)
    }

    private func load() -> FamiliarStudioEnvelope? {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> FamiliarStudioEnvelope? {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? PropertyListDecoder().decode(
                FamiliarStudioEnvelope.self, from: data),
              value.schemaVersion == FamiliarStudioEnvelope.schemaVersion else { return nil }
        return value
    }

    private static func references(from raw: Any?) throws -> [StoredStudioReference] {
        guard let rows = raw as? [[String: Any]], rows.count <= 8 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var ids = Set<String>(), total = 0
        return try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  id.utf8.count <= 100, ids.insert(id).inserted,
                  let source = row["source"] as? String,
                  let decoded = decodeDataURI(source),
                  decoded.data.count <= maximumReferenceBytes else {
                throw CocoaError(.fileWriteFileExists)
            }
            total += decoded.data.count
            guard total <= maximumReferenceSetBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            return StoredStudioReference(
                id: id, name: String((row["name"] as? String ?? "").prefix(160)),
                mimeType: decoded.mimeType, data: decoded.data,
                width: (row["width"] as? NSNumber)?.intValue,
                height: (row["height"] as? NSNumber)?.intValue)
        }
    }

    private static func decodeDataURI(_ value: String) -> (mimeType: String, data: Data)? {
        guard value.utf8.count <= (maximumReferenceBytes * 4 / 3 + 1_024),
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = String(value[..<comma]).lowercased()
        let mimeType: String
        if header == "data:image/png;base64" { mimeType = "image/png" }
        else if header == "data:image/jpeg;base64" || header == "data:image/jpg;base64" {
            mimeType = "image/jpeg"
        } else if header == "data:image/webp;base64" { mimeType = "image/webp" }
        else { return nil }
        guard let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
              !data.isEmpty else { return nil }
        return (mimeType, data)
    }

    private static func dataURI(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64," + data.base64EncodedString()
    }
}
