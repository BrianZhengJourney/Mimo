// Mimo — durable import seam for externally generated action results.
//
// The app does not launch Wan, Modal, or Python. It accepts one deliberately
// small result-bundle contract, validates/copies those files into app-owned
// storage, then lets Settings preview and explicitly install the strip.

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import WebKit

struct ActionResultBundleMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let action: String
    let stripFilename: String
    let frameCount: Int
    let cellSize: Int
    let framesPerSecond: Double
    /// Distance covered by one full cycle in source-cell pixels, not screen px.
    let cycleDistanceCellPixels: Double?
    /// Fixed registration point in the 512px cell, in image space (y-down).
    let anchorInCell: [Double]?
    let qaFilename: String
    /// External generators must never authorize their own installation. Mimo
    /// always requires an explicit user accept after preview.
    let automaticInstallAllowed: Bool
}

struct ActionGenerationJobRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: String
    let characterID: String
    let sourceLabel: String
    let createdAt: Date
    let metadata: ActionResultBundleMetadata
    let stripAsset: String
    let previewAsset: String?
    let checkerAsset: String?
    /// nil when no machine-readable checker was supplied.
    let checkerPassed: Bool?
    var installedAt: Date?

    /// External output is never self-authorizing. This only means the bundle
    /// passed hard QA and has the locomotion facts needed for a user-triggered
    /// install; the Settings Accept click is still mandatory.
    var isEligibleForManualInstall: Bool {
        metadata.automaticInstallAllowed == false
            && checkerPassed == true
            && (metadata.action != "walk" || metadata.cycleDistanceCellPixels != nil)
    }
}

enum ActionGenerationJobError: LocalizedError {
    case invalidCharacterID
    case unsafeBundle
    case unknownBundleFile(String)
    case missingRequiredFile(String)
    case invalidMetadata
    case invalidStrip
    case invalidPreview
    case invalidChecker
    case missingJob
    case corruptJob
    case unsafeAsset

    var errorDescription: String? {
        switch self {
        case .invalidCharacterID: return "The action result does not target a valid custom familiar."
        case .unsafeBundle: return "The selected action result folder is not safe to import."
        case .unknownBundleFile(let name): return "The action result contains an unsupported file: \(name)."
        case .missingRequiredFile(let name): return "The action result is missing \(name)."
        case .invalidMetadata: return "The action result metadata is invalid."
        case .invalidStrip: return "strip.png is not a valid 512px-cell action strip."
        case .invalidPreview: return "The optional action preview is invalid."
        case .invalidChecker: return "The optional action checker is invalid."
        case .missingJob: return "The imported action result could not be found."
        case .corruptJob: return "The imported action result is corrupt."
        case .unsafeAsset: return "The imported action asset path is unsafe."
        }
    }
}

final class ActionGenerationJobStore: @unchecked Sendable {
    static let folderName = "ActionGenerationJobs"
    static let recordFilename = "job.json"
    static let metadataFilename = "metadata.json"
    static let stripFilename = "strip.png"
    static let previewFilename = "preview.png"
    static let checkerFilename = "checker.json"
    static let scheme = "mimo-action-job"
    static let schemeHost = "asset"
    static let assetRevision = "1"
    static let maximumMetadataBytes = 64 * 1024
    static let maximumPreviewBytes = 16 * 1024 * 1024
    static let maximumCheckerBytes = 4 * 1024 * 1024
    static let maximumRecordBytes = 128 * 1024

    private let fileManager: FileManager
    private let rootURL: URL
    private let jobsURL: URL
    private let lock = NSLock()

    init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rootURL = root.standardizedFileURL
        jobsURL = root.standardizedFileURL.appendingPathComponent(Self.folderName,
                                                                   isDirectory: true)
        if (try? prepareStorage()) != nil { cleanupTransactions() }
    }

    var folderURL: URL { jobsURL }

    @discardableResult
    func importResultBundle(at sourceURL: URL, characterID: String,
                            now: Date = Date(), id: UUID = UUID()) throws
        -> ActionGenerationJobRecord {
        try synchronized {
            try prepareStorage()
            let canonicalCharacterID = try Self.canonicalCharacterID(characterID)
            let source = sourceURL.standardizedFileURL
            guard Self.isSafeDirectory(source, fileManager: fileManager) else {
                throw ActionGenerationJobError.unsafeBundle
            }

            let entries = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                              .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
            let metadataEntries = entries.filter {
                $0.lastPathComponent.hasPrefix("action-")
                    && $0.lastPathComponent.hasSuffix(".metadata.json")
            }
            guard metadataEntries.count == 1, let metadataURL = metadataEntries.first else {
                throw ActionGenerationJobError.missingRequiredFile("action-<name>.metadata.json")
            }
            let metadataData = try Self.safeRead(metadataURL,
                                                 maximumBytes: Self.maximumMetadataBytes)
            let metadata = try Self.decodeMetadata(metadataData)
            let prefix = "action-\(metadata.action)"
            guard metadataURL.lastPathComponent == "\(prefix).metadata.json",
                  metadata.stripFilename == "\(prefix).png",
                  metadata.qaFilename == "\(prefix).qa.json" else {
                throw ActionGenerationJobError.invalidMetadata
            }
            let previewSourceFilename = "\(prefix)-contact-sheet.png"
            let allowed = Set([
                metadata.stripFilename, metadataURL.lastPathComponent,
                metadata.qaFilename, previewSourceFilename, ".DS_Store",
            ])
            for entry in entries where !allowed.contains(entry.lastPathComponent) {
                throw ActionGenerationJobError.unknownBundleFile(entry.lastPathComponent)
            }

            let stripURL = source.appendingPathComponent(metadata.stripFilename,
                                                          isDirectory: false)
            guard fileManager.fileExists(atPath: stripURL.path) else {
                throw ActionGenerationJobError.missingRequiredFile(metadata.stripFilename)
            }
            let qaURL = source.appendingPathComponent(metadata.qaFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: qaURL.path) else {
                throw ActionGenerationJobError.missingRequiredFile(metadata.qaFilename)
            }
            let stripData = try Self.safeRead(stripURL,
                                              maximumBytes: CustomPetStore.maximumActionPNGBytes)
            try Self.validateStrip(stripData, metadata: metadata)

            let preview: (String, Data)? = try {
                let sourceURL = source.appendingPathComponent(previewSourceFilename)
                guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
                let data = try Self.safeRead(sourceURL,
                                             maximumBytes: Self.maximumPreviewBytes)
                try Self.validateRaster(data, filename: previewSourceFilename,
                                        allowAnimation: false)
                return (Self.previewFilename, data)
            }()
            let qaData = try Self.safeRead(qaURL, maximumBytes: Self.maximumCheckerBytes)
            let checker = (Self.checkerFilename, qaData,
                           try Self.decodeCheckerPassed(qaData))

            let jobID = id.uuidString.lowercased()
            let destination = jobDirectory(jobID)
            guard !fileManager.fileExists(atPath: destination.path),
                  Self.isDescendant(destination, of: jobsURL) else {
                throw ActionGenerationJobError.unsafeAsset
            }
            let temporary = jobsURL.appendingPathComponent(
                ".import-\(jobID)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            var cleanup = true
            defer { if cleanup { try? fileManager.removeItem(at: temporary) } }

            try stripData.write(to: temporary.appendingPathComponent(Self.stripFilename),
                                options: [.atomic])
            try Self.encodeMetadata(metadata).write(
                to: temporary.appendingPathComponent(Self.metadataFilename), options: [.atomic])
            if let preview {
                try preview.1.write(to: temporary.appendingPathComponent(preview.0), options: [.atomic])
            }
            try checker.1.write(to: temporary.appendingPathComponent(checker.0), options: [.atomic])
            let sourceLabel = Self.safeLabel(source.lastPathComponent)
            let record = ActionGenerationJobRecord(
                schemaVersion: ActionGenerationJobRecord.schemaVersion,
                id: jobID,
                characterID: canonicalCharacterID,
                sourceLabel: sourceLabel,
                createdAt: now,
                metadata: metadata,
                stripAsset: Self.stripFilename,
                previewAsset: preview?.0,
                checkerAsset: checker.0,
                checkerPassed: checker.2,
                installedAt: nil
            )
            try Self.encodeRecord(record).write(
                to: temporary.appendingPathComponent(Self.recordFilename), options: [.atomic])
            for filename in [Self.stripFilename, Self.metadataFilename, Self.recordFilename]
                + [preview?.0, checker.0].compactMap({ $0 }) {
                try? fileManager.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: temporary.appendingPathComponent(filename).path)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            cleanup = false
            return record
        }
    }

    func jobs(characterID: String? = nil) -> [ActionGenerationJobRecord] {
        (try? synchronized {
            try prepareStorage()
            let canonical = try characterID.map(Self.canonicalCharacterID)
            let entries = try fileManager.contentsOfDirectory(
                at: jobsURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return entries.compactMap { entry in
                guard UUID(uuidString: entry.lastPathComponent) != nil,
                      let record = try? loadRecord(entry.lastPathComponent),
                      canonical == nil || record.characterID == canonical else { return nil }
                return record
            }.sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id > rhs.id : lhs.createdAt > rhs.createdAt
            }
        }) ?? []
    }

    func record(jobID: String) throws -> ActionGenerationJobRecord {
        try synchronized {
            try prepareStorage()
            return try loadRecord(Self.canonicalJobID(jobID))
        }
    }

    func stripData(jobID: String) throws -> Data {
        try synchronized {
            try prepareStorage()
            let canonical = try Self.canonicalJobID(jobID)
            let record = try loadRecord(canonical)
            let url = jobDirectory(canonical).appendingPathComponent(record.stripAsset)
            guard record.stripAsset == Self.stripFilename,
                  Self.isDescendant(url, of: jobsURL) else {
                throw ActionGenerationJobError.unsafeAsset
            }
            let data = try Self.safeRead(url, maximumBytes: CustomPetStore.maximumActionPNGBytes)
            try Self.validateStrip(data, metadata: record.metadata)
            return data
        }
    }

    @discardableResult
    func markInstalled(jobID: String, now: Date = Date()) throws -> ActionGenerationJobRecord {
        try synchronized {
            try prepareStorage()
            let canonical = try Self.canonicalJobID(jobID)
            var record = try loadRecord(canonical)
            record.installedAt = now
            let url = jobDirectory(canonical).appendingPathComponent(Self.recordFilename)
            try Self.encodeRecord(record).write(to: url, options: [.atomic])
            return record
        }
    }

    func runtimeDictionary(for record: ActionGenerationJobRecord) -> [String: Any] {
        var value: [String: Any] = [
            "jobID": record.id,
            "characterID": record.characterID,
            "sourceLabel": record.sourceLabel,
            "createdAt": ISO8601DateFormatter().string(from: record.createdAt),
            "action": record.metadata.action,
            "frameCount": record.metadata.frameCount,
            "fps": record.metadata.framesPerSecond,
            "stripURL": assetURL(jobID: record.id, filename: record.stripAsset),
            "installed": record.installedAt != nil,
            "installEligible": record.isEligibleForManualInstall,
        ]
        if let installedAt = record.installedAt {
            value["installedAt"] = ISO8601DateFormatter().string(from: installedAt)
        }
        if let cycleDistance = record.metadata.cycleDistanceCellPixels {
            value["cycleDistanceCellPixels"] = cycleDistance
            value["cycleDistanceUnits"] = "cell-pixels"
        }
        if let anchor = record.metadata.anchorInCell, anchor.count == 2 {
            value["anchorX"] = anchor[0]
            value["anchorY"] = anchor[1]
        }
        if let preview = record.previewAsset {
            value["previewURL"] = assetURL(jobID: record.id, filename: preview)
        }
        if let checker = record.checkerAsset {
            value["checkerPresent"] = true
            if let checkerPassed = record.checkerPassed {
                value["checkerPassed"] = checkerPassed
            }
            if checker.hasSuffix(".png") {
                value["checkerURL"] = assetURL(jobID: record.id, filename: checker)
            }
        }
        return value
    }

    func runtimeDictionaries(characterID: String? = nil) -> [[String: Any]] {
        jobs(characterID: characterID).map(runtimeDictionary)
    }

    struct AssetResponse {
        let data: Data
        let mimeType: String
    }

    func asset(for url: URL) throws -> AssetResponse {
        try synchronized {
            try prepareStorage()
            let location = try Self.assetLocation(url)
            let record = try loadRecord(location.jobID)
            let allowed = Set([record.stripAsset, record.previewAsset, record.checkerAsset]
                .compactMap({ $0 })).filter { !$0.hasSuffix(".json") }
            guard allowed.contains(location.filename) else {
                throw ActionGenerationJobError.unsafeAsset
            }
            let fileURL = jobDirectory(location.jobID).appendingPathComponent(location.filename)
            guard Self.isDescendant(fileURL, of: jobsURL) else {
                throw ActionGenerationJobError.unsafeAsset
            }
            let maximum = location.filename == Self.stripFilename
                ? CustomPetStore.maximumActionPNGBytes
                : (location.filename.hasPrefix("preview.")
                    ? Self.maximumPreviewBytes : Self.maximumCheckerBytes)
            let data = try Self.safeRead(fileURL, maximumBytes: maximum)
            let mime = location.filename.hasSuffix(".gif") ? "image/gif" : "image/png"
            return AssetResponse(data: data, mimeType: mime)
        }
    }

    private func loadRecord(_ jobID: String) throws -> ActionGenerationJobRecord {
        let directory = jobDirectory(jobID)
        let recordURL = directory.appendingPathComponent(Self.recordFilename)
        guard Self.isSafeDirectory(directory, fileManager: fileManager),
              Self.isDescendant(recordURL, of: jobsURL),
              let data = try? Self.safeRead(recordURL, maximumBytes: Self.maximumRecordBytes) else {
            throw ActionGenerationJobError.missingJob
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(ActionGenerationJobRecord.self, from: data),
              record.schemaVersion == ActionGenerationJobRecord.schemaVersion,
              record.id == jobID,
              (try? Self.canonicalCharacterID(record.characterID)) == record.characterID,
              record.stripAsset == Self.stripFilename,
              Self.validMetadata(record.metadata),
              record.previewAsset == nil || record.previewAsset == Self.previewFilename,
              record.checkerAsset == Self.checkerFilename,
              record.checkerPassed != nil else {
            throw ActionGenerationJobError.corruptJob
        }
        return record
    }

    private func jobDirectory(_ jobID: String) -> URL {
        jobsURL.appendingPathComponent(jobID, isDirectory: true)
    }

    private func assetURL(jobID: String, filename: String) -> String {
        "\(Self.scheme)://\(Self.schemeHost)/\(jobID)/\(filename)?v=\(Self.assetRevision)"
    }

    private func prepareStorage() throws {
        try Self.ensureDirectory(rootURL, fileManager: fileManager)
        guard Self.isSafeDirectory(rootURL, fileManager: fileManager) else {
            throw ActionGenerationJobError.unsafeAsset
        }
        try Self.ensureDirectory(jobsURL, fileManager: fileManager)
        guard Self.isSafeDirectory(jobsURL, fileManager: fileManager),
              Self.isDescendant(jobsURL, of: rootURL) else {
            throw ActionGenerationJobError.unsafeAsset
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = jobsURL
        _ = try? mutable.setResourceValues(values)
    }

    private func cleanupTransactions() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: jobsURL, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".import-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func decodeMetadata(_ data: Data) throws
        -> ActionResultBundleMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: [
                  "schemaVersion", "action", "stripFilename", "frameCount", "cellSize",
                  "framesPerSecond", "cycleDistanceCellPixels", "anchorInCell",
                  "qaFilename", "automaticInstallAllowed",
              ]) else { throw ActionGenerationJobError.invalidMetadata }
        if let anchor = object["anchorInCell"] {
            guard let value = anchor as? [NSNumber], value.count == 2 else {
                throw ActionGenerationJobError.invalidMetadata
            }
        }
        guard let metadata = try? JSONDecoder().decode(ActionResultBundleMetadata.self, from: data),
              validMetadata(metadata) else {
            throw ActionGenerationJobError.invalidMetadata
        }
        return metadata
    }

    private static func validMetadata(_ metadata: ActionResultBundleMetadata) -> Bool {
        let prefix = "action-\(metadata.action)"
        guard metadata.schemaVersion == ActionResultBundleMetadata.schemaVersion,
              CustomPetStore.isActionName(metadata.action),
              metadata.stripFilename == "\(prefix).png",
              metadata.qaFilename == "\(prefix).qa.json",
              metadata.cellSize == CustomPetStore.actionCellSize,
              metadata.automaticInstallAllowed == false,
              CustomPetStore.actionFrameRange.contains(metadata.frameCount),
              metadata.framesPerSecond.isFinite,
              CustomPetStore.actionFPSRange.contains(metadata.framesPerSecond),
              metadata.cycleDistanceCellPixels.map({
                  $0.isFinite && CustomPetStore.actionCycleDistanceRange.contains($0)
              }) ?? true else { return false }
        guard let anchor = metadata.anchorInCell else { return true }
        guard anchor.count == 2 else { return false }
        let range = 0...Double(CustomPetStore.actionCellSize)
        return anchor[0].isFinite && anchor[1].isFinite
            && range.contains(anchor[0]) && range.contains(anchor[1])
    }

    private static func validateStrip(_ data: Data,
                                      metadata: ActionResultBundleMetadata) throws {
        guard data.count <= CustomPetStore.maximumActionPNGBytes,
              let dimensions = CharacterSheetProcessor.pngPixelDimensions(data),
              dimensions.height == CustomPetStore.actionCellSize,
              dimensions.width == metadata.frameCount * CustomPetStore.actionCellSize else {
            throw ActionGenerationJobError.invalidStrip
        }
    }

    private static func decodeCheckerPassed(_ data: Data) throws -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              let passed = object["hardPass"] as? Bool,
              object["automaticInstallAllowed"] as? Bool == false,
              object["manualReviewRequired"] as? Bool == true else {
            throw ActionGenerationJobError.invalidChecker
        }
        return passed
    }

    private static func validateRaster(_ data: Data, filename: String,
                                       allowAnimation: Bool) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              allowAnimation || CGImageSourceGetCount(source) == 1,
              CGImageSourceGetCount(source) <= 256,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              width.intValue <= 8192, height.intValue <= 8192,
              width.intValue * height.intValue <= 32_000_000 else {
            if filename.contains("contact-sheet") || filename.hasPrefix("preview.") {
                throw ActionGenerationJobError.invalidPreview
            }
            throw ActionGenerationJobError.invalidChecker
        }
    }

    private static func encodeMetadata(_ metadata: ActionResultBundleMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    private static func encodeRecord(_ record: ActionGenerationJobRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(record)
    }

    private static func canonicalCharacterID(_ value: String) throws -> String {
        guard value.hasPrefix(CustomPetStore.characterPrefix) else {
            throw ActionGenerationJobError.invalidCharacterID
        }
        let suffix = String(value.dropFirst(CustomPetStore.characterPrefix.count))
        guard let uuid = UUID(uuidString: suffix),
              suffix.caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw ActionGenerationJobError.invalidCharacterID
        }
        return CustomPetStore.characterPrefix + uuid.uuidString.lowercased()
    }

    private static func canonicalJobID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value),
              value.caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw ActionGenerationJobError.missingJob
        }
        return uuid.uuidString.lowercased()
    }

    private static func safeLabel(_ value: String) -> String {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let label = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((label.isEmpty ? "Wan result" : label).prefix(80))
    }

    private static func safeRead(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ActionGenerationJobError.unsafeAsset }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0, status.st_size <= maximumBytes else {
            throw ActionGenerationJobError.unsafeAsset
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        guard data.count <= maximumBytes else { throw ActionGenerationJobError.unsafeAsset }
        return data
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ActionGenerationJobError.unsafeAsset }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    private static func isSafeDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
    }

    private struct AssetLocation {
        let jobID: String
        let filename: String
    }

    private static func assetLocation(_ url: URL) throws -> AssetLocation {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == schemeHost,
              components.user == nil, components.password == nil, components.port == nil,
              components.percentEncodedQuery == "v=\(assetRevision)",
              components.fragment == nil, !components.percentEncodedPath.contains("%") else {
            throw ActionGenerationJobError.unsafeAsset
        }
        let path = components.percentEncodedPath.split(separator: "/",
                                                       omittingEmptySubsequences: true)
        guard path.count == 2,
              let uuid = UUID(uuidString: String(path[0])),
              String(path[0]).caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw ActionGenerationJobError.unsafeAsset
        }
        let jobID = uuid.uuidString.lowercased()
        let filename = String(path[1])
        guard components.percentEncodedPath == "/\(jobID)/\(filename)" else {
            throw ActionGenerationJobError.unsafeAsset
        }
        return AssetLocation(jobID: jobID, filename: filename)
    }
}

final class ActionGenerationJobAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: ActionGenerationJobStore

    init(store: ActionGenerationJobStore) { self.store = store }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        serve(urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func serve(_ task: WKURLSchemeTask) {
        guard let url = task.request.url,
              ["GET", "HEAD"].contains(task.request.httpMethod?.uppercased() ?? "GET") else {
            task.didFailWithError(ActionGenerationJobError.unsafeAsset)
            return
        }
        do {
            let asset = try store.asset(for: url)
            let response = URLResponse(url: url, mimeType: asset.mimeType,
                                       expectedContentLength: asset.data.count,
                                       textEncodingName: nil)
            task.didReceive(response)
            if task.request.httpMethod?.uppercased() != "HEAD" { task.didReceive(asset.data) }
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }
}
