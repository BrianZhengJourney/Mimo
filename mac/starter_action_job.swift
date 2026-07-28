import Foundation
import ImageIO

enum StarterActionJobState: String, Codable, CaseIterable, Sendable {
    case planned
    case queued
    case generating
    case localProcessing = "local_processing"
    case awaitingReview = "awaiting_review"
    case installed
    case failed
    case cancelled

    var isInFlight: Bool {
        self == .queued || self == .generating || self == .localProcessing
    }
}

struct StarterActionJobRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumAttempts = 3

    let schemaVersion: Int
    let id: String
    let characterID: String
    let actionID: StarterActionID
    var state: StarterActionJobState
    let createdAt: Date
    var updatedAt: Date
    var attempt: Int
    let maximumAttempts: Int
    var requestID: String?
    var quality: String
    var phase: String?
    var completedBatches: Int
    var estimatedProviderCalls: Int
    var usedProviderCalls: Int
    var resultJobID: String?
    var errorCode: String?
    var errorMessage: String?

    var canStart: Bool {
        [.planned, .failed, .cancelled].contains(state)
            && attempt < maximumAttempts
    }

    var canCancel: Bool { state.isInFlight }
    var canReview: Bool { state == .awaitingReview && resultJobID != nil }
}

enum StarterActionJobError: LocalizedError {
    case invalidCharacterID
    case invalidJobID
    case invalidRequestID
    case invalidResultID
    case invalidQuality
    case missingJob
    case corruptStore
    case invalidTransition
    case attemptLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidCharacterID: return "The starter action does not target a valid custom familiar."
        case .invalidJobID: return "The starter action job ID is invalid."
        case .invalidRequestID: return "The starter action request ID is invalid."
        case .invalidResultID: return "The generated action result ID is invalid."
        case .invalidQuality: return "The starter action quality is invalid."
        case .missingJob: return "The starter action job could not be found."
        case .corruptStore: return "The starter action job store is corrupt."
        case .invalidTransition: return "The starter action job cannot make that state transition."
        case .attemptLimitReached: return "The starter action has reached its retry limit."
        }
    }
}

/// Durable orchestration state for the four Studio action cards.
///
/// Generated artifacts remain in ActionGenerationJobStore. This store owns
/// only the paid/local workflow state and links to the immutable result once it
/// is ready for manual review. Splitting the two keeps an interrupted request
/// from corrupting an already reviewable action bundle.
final class StarterActionJobStore: @unchecked Sendable {
    static let folderName = "StarterActionJobs"
    static let recordFilename = "job.json"
    static let maximumRecordBytes = 64 * 1024
    static let maximumBatchBytes = 20 * 1024 * 1024

    private let fileManager: FileManager
    private let jobsURL: URL
    private let lock = NSLock()

    init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        jobsURL = root.standardizedFileURL.appendingPathComponent(
            Self.folderName, isDirectory: true)
        if (try? prepareStorage()) != nil {
            recoverInterruptedJobs()
        }
    }

    @discardableResult
    func ensureJobs(characterID: String, now: Date = Date()) throws
        -> [StarterActionJobRecord] {
        try synchronized {
            try prepareStorage()
            let characterID = try Self.canonicalCharacterID(characterID)
            var existing = try loadAll().filter { $0.characterID == characterID }
            for index in existing.indices {
                let definition = StarterActionCatalog.definition(existing[index].actionID)
                guard existing[index].estimatedProviderCalls
                        != definition.estimatedProviderCalls,
                      [.planned, .failed, .cancelled].contains(existing[index].state),
                      existing[index].completedBatches == 0,
                      existing[index].usedProviderCalls == 0,
                      existing[index].resultJobID == nil else { continue }
                existing[index].estimatedProviderCalls = definition.estimatedProviderCalls
                existing[index].updatedAt = now
                try persist(existing[index])
            }
            for actionID in StarterActionID.allCases
                where !existing.contains(where: { $0.actionID == actionID }) {
                let definition = StarterActionCatalog.definition(actionID)
                let record = StarterActionJobRecord(
                    schemaVersion: StarterActionJobRecord.schemaVersion,
                    id: UUID().uuidString.lowercased(),
                    characterID: characterID,
                    actionID: actionID,
                    state: .planned,
                    createdAt: now,
                    updatedAt: now,
                    attempt: 0,
                    maximumAttempts: StarterActionJobRecord.maximumAttempts,
                    requestID: nil,
                    quality: "medium",
                    phase: nil,
                    completedBatches: 0,
                    estimatedProviderCalls: definition.estimatedProviderCalls,
                    usedProviderCalls: 0,
                    resultJobID: nil,
                    errorCode: nil,
                    errorMessage: nil)
                try persist(record)
                existing.append(record)
            }
            return Self.productOrdered(existing)
        }
    }

    func jobs(characterID: String? = nil) -> [StarterActionJobRecord] {
        (try? synchronized {
            try prepareStorage()
            let canonical = try characterID.map(Self.canonicalCharacterID)
            let records = try loadAll().filter {
                canonical == nil || $0.characterID == canonical
            }
            return Self.productOrdered(records)
        }) ?? []
    }

    func record(jobID: String) throws -> StarterActionJobRecord {
        try synchronized {
            try prepareStorage()
            return try loadRecord(Self.canonicalUUID(jobID, error: .invalidJobID))
        }
    }

    @discardableResult
    func queue(jobID: String, requestID: String, quality: String,
               now: Date = Date()) throws -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.canStart else {
                if record.attempt >= record.maximumAttempts {
                    throw StarterActionJobError.attemptLimitReached
                }
                throw StarterActionJobError.invalidTransition
            }
            guard quality == "medium" || quality == "high" else {
                throw StarterActionJobError.invalidQuality
            }
            record.state = .queued
            record.updatedAt = now
            record.attempt += 1
            record.requestID = try Self.canonicalUUID(
                requestID, error: .invalidRequestID)
            record.quality = quality
            record.phase = "queued"
            record.resultJobID = nil
            record.errorCode = nil
            record.errorMessage = nil
        }
    }

    @discardableResult
    func markGenerating(jobID: String, phase: String,
                        completedBatches: Int, usedProviderCalls: Int,
                        requestID: String? = nil,
                        now: Date = Date()) throws -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.state == .queued || record.state == .generating,
                  completedBatches == record.completedBatches,
                  usedProviderCalls == record.usedProviderCalls else {
                throw StarterActionJobError.invalidTransition
            }
            record.state = .generating
            record.updatedAt = now
            record.phase = Self.safeText(phase)
            record.completedBatches = completedBatches
            record.usedProviderCalls = usedProviderCalls
            if let requestID {
                record.requestID = try Self.canonicalUUID(
                    requestID, error: .invalidRequestID)
            }
        }
    }

    /// Checkpoints one paid provider result immediately. Batches are strictly
    /// sequential, so a restart can resume from `completedBatches` without
    /// silently regenerating anything already returned.
    @discardableResult
    func storeCompletedBatch(jobID: String, batchIndex: Int,
                             pngData: Data, usedProviderCalls: Int,
                             now: Date = Date()) throws -> StarterActionJobRecord {
        try synchronized {
            try prepareStorage()
            let id = try Self.canonicalUUID(jobID, error: .invalidJobID)
            var record = try loadRecord(id)
            guard record.state == .generating,
                  batchIndex == record.completedBatches,
                  (0..<record.estimatedProviderCalls).contains(batchIndex),
                  usedProviderCalls == record.usedProviderCalls + 1,
                  usedProviderCalls <= record.estimatedProviderCalls * record.maximumAttempts,
                  Self.isValidBatchPNG(pngData) else {
                throw StarterActionJobError.invalidTransition
            }
            let filename = Self.batchFilename(batchIndex)
            let url = jobsURL.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(filename)
            guard Self.isDescendant(url, of: jobsURL),
                  !fileManager.fileExists(atPath: url.path) else {
                throw StarterActionJobError.corruptStore
            }
            try pngData.write(to: url, options: [.atomic])
            var committed = false
            defer { if !committed { try? fileManager.removeItem(at: url) } }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            record.updatedAt = now
            record.phase = "batch-\(batchIndex + 1)-complete"
            record.completedBatches = batchIndex + 1
            record.usedProviderCalls = usedProviderCalls
            try persist(record)
            committed = true
            return record
        }
    }

    func batchData(jobID: String, batchIndex: Int) throws -> Data {
        try synchronized {
            try prepareStorage()
            let id = try Self.canonicalUUID(jobID, error: .invalidJobID)
            let record = try loadRecord(id)
            guard (0..<record.completedBatches).contains(batchIndex) else {
                throw StarterActionJobError.missingJob
            }
            let url = jobsURL.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(Self.batchFilename(batchIndex))
            guard Self.isDescendant(url, of: jobsURL),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= Self.maximumBatchBytes,
                  let data = try? Data(contentsOf: url),
                  Self.isValidBatchPNG(data) else {
                throw StarterActionJobError.corruptStore
            }
            return data
        }
    }

    func completedBatchData(jobID: String) throws -> [Data] {
        let record = try record(jobID: jobID)
        return try (0..<record.completedBatches).map {
            try batchData(jobID: record.id, batchIndex: $0)
        }
    }

    @discardableResult
    func markLocalProcessing(jobID: String, phase: String,
                             now: Date = Date()) throws -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.state == .generating else {
                throw StarterActionJobError.invalidTransition
            }
            record.state = .localProcessing
            record.updatedAt = now
            record.phase = Self.safeText(phase)
            record.requestID = nil
            record.completedBatches = record.estimatedProviderCalls
        }
    }

    @discardableResult
    func markAwaitingReview(jobID: String, resultJobID: String,
                            now: Date = Date()) throws -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.state == .localProcessing else {
                throw StarterActionJobError.invalidTransition
            }
            record.state = .awaitingReview
            record.updatedAt = now
            record.phase = "awaiting-review"
            record.resultJobID = try Self.canonicalUUID(
                resultJobID, error: .invalidResultID)
            record.requestID = nil
            record.errorCode = nil
            record.errorMessage = nil
        }
    }

    @discardableResult
    func markInstalled(jobID: String, now: Date = Date()) throws
        -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.canReview else {
                throw StarterActionJobError.invalidTransition
            }
            record.state = .installed
            record.updatedAt = now
            record.phase = "installed"
        }
    }

    @discardableResult
    func markFailed(jobID: String, code: String, message: String,
                    usedProviderCalls: Int? = nil, now: Date = Date()) throws
        -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.state.isInFlight else {
                throw StarterActionJobError.invalidTransition
            }
            if let usedProviderCalls {
                guard (record.usedProviderCalls...(record.estimatedProviderCalls
                       * record.maximumAttempts))
                    .contains(usedProviderCalls) else {
                    throw StarterActionJobError.invalidTransition
                }
                record.usedProviderCalls = usedProviderCalls
            }
            record.state = .failed
            record.updatedAt = now
            record.phase = "failed"
            record.requestID = nil
            record.errorCode = Self.safeText(code)
            record.errorMessage = Self.safeText(message)
        }
    }

    @discardableResult
    func cancel(jobID: String, now: Date = Date()) throws -> StarterActionJobRecord {
        try update(jobID: jobID) { record in
            guard record.canCancel else {
                throw StarterActionJobError.invalidTransition
            }
            record.state = .cancelled
            record.updatedAt = now
            record.phase = "cancelled"
            record.requestID = nil
            record.errorCode = nil
            record.errorMessage = nil
        }
    }

    func runtimeDictionary(for record: StarterActionJobRecord) -> [String: Any] {
        let definition = StarterActionCatalog.definition(record.actionID)
        let finalFrameCount = record.actionID == .gaze
            && record.estimatedProviderCalls == 2
            ? 5 : definition.finalFrameCount
        var value: [String: Any] = [
            "jobID": record.id,
            "characterID": record.characterID,
            "actionID": record.actionID.rawValue,
            "action": definition.manifestActionName,
            "titleZh": definition.titleZh,
            "titleEn": definition.titleEn,
            "state": record.state.rawValue,
            "attempt": record.attempt,
            "maximumAttempts": record.maximumAttempts,
            "estimatedProviderCalls": record.estimatedProviderCalls,
            "usedProviderCalls": record.usedProviderCalls,
            "completedBatches": record.completedBatches,
            "finalFrameCount": finalFrameCount,
            "quality": record.quality,
            "canStart": record.canStart,
            "canCancel": record.canCancel,
            "canReview": record.canReview,
        ]
        if let phase = record.phase { value["phase"] = phase }
        if let resultJobID = record.resultJobID { value["resultJobID"] = resultJobID }
        if let errorCode = record.errorCode { value["errorCode"] = errorCode }
        if let errorMessage = record.errorMessage { value["errorMessage"] = errorMessage }
        return value
    }

    func runtimeDictionaries(characterID: String? = nil) -> [[String: Any]] {
        jobs(characterID: characterID).map(runtimeDictionary)
    }

    // MARK: - Persistence

    private func update(jobID: String,
                        mutate: (inout StarterActionJobRecord) throws -> Void) throws
        -> StarterActionJobRecord {
        try synchronized {
            try prepareStorage()
            let id = try Self.canonicalUUID(jobID, error: .invalidJobID)
            var record = try loadRecord(id)
            try mutate(&record)
            try persist(record)
            return record
        }
    }

    private func recoverInterruptedJobs() {
        try? synchronized {
            for var record in try loadAll() where record.state.isInFlight {
                record.state = .failed
                record.updatedAt = Date()
                record.phase = "interrupted"
                record.requestID = nil
                record.errorCode = "interrupted"
                record.errorMessage = "Mimo closed before this action finished. Review the recorded calls, then retry explicitly."
                try persist(record)
            }
        }
    }

    private func prepareStorage() throws {
        try fileManager.createDirectory(
            at: jobsURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func loadAll() throws -> [StarterActionJobRecord] {
        let entries = try fileManager.contentsOfDirectory(
            at: jobsURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return entries.compactMap { entry in
            guard UUID(uuidString: entry.lastPathComponent) != nil else { return nil }
            return try? loadRecord(entry.lastPathComponent.lowercased())
        }
    }

    private func loadRecord(_ id: String) throws -> StarterActionJobRecord {
        let directory = jobsURL.appendingPathComponent(id, isDirectory: true)
        let url = directory.appendingPathComponent(Self.recordFilename)
        guard Self.isDescendant(directory, of: jobsURL),
              let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumRecordBytes,
              let record = try? JSONDecoder().decode(StarterActionJobRecord.self, from: data),
              record.schemaVersion == StarterActionJobRecord.schemaVersion,
              record.id == id,
              (1...12).contains(record.estimatedProviderCalls),
              (0...record.estimatedProviderCalls).contains(record.completedBatches),
              (0...(record.estimatedProviderCalls * record.maximumAttempts))
                .contains(record.usedProviderCalls) else {
            throw StarterActionJobError.missingJob
        }
        return record
    }

    private func persist(_ record: StarterActionJobRecord) throws {
        guard record.schemaVersion == StarterActionJobRecord.schemaVersion,
              record.id == (try? Self.canonicalUUID(record.id, error: .invalidJobID)),
              record.characterID == (try? Self.canonicalCharacterID(record.characterID)),
              (0...record.maximumAttempts).contains(record.attempt),
              (0...record.estimatedProviderCalls).contains(record.completedBatches),
              (0...(record.estimatedProviderCalls * record.maximumAttempts))
                .contains(record.usedProviderCalls) else {
            throw StarterActionJobError.corruptStore
        }
        let directory = jobsURL.appendingPathComponent(record.id, isDirectory: true)
        guard Self.isDescendant(directory, of: jobsURL) else {
            throw StarterActionJobError.corruptStore
        }
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw StarterActionJobError.corruptStore
        }
        let url = directory.appendingPathComponent(Self.recordFilename)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600],
                                       ofItemAtPath: url.path)
    }

    private static func canonicalCharacterID(_ value: String) throws -> String {
        guard value.hasPrefix("custom:"),
              let uuid = UUID(uuidString: String(value.dropFirst("custom:".count))) else {
            throw StarterActionJobError.invalidCharacterID
        }
        return "custom:\(uuid.uuidString.lowercased())"
    }

    private static func canonicalUUID(_ value: String,
                                      error: StarterActionJobError) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw error }
        return uuid.uuidString.lowercased()
    }

    private static func safeText(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\0", with: "").prefix(512))
    }

    private static func batchFilename(_ index: Int) -> String {
        String(format: "batch-%02d.png", index + 1)
    }

    private static func isValidBatchPNG(_ data: Data) -> Bool {
        guard data.count <= maximumBatchBytes,
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        return width.intValue == 1536 && height.intValue == 1024
    }

    private static func productOrdered(_ records: [StarterActionJobRecord])
        -> [StarterActionJobRecord] {
        let order = Dictionary(uniqueKeysWithValues:
            StarterActionID.allCases.enumerated().map { ($0.element, $0.offset) })
        return records.sorted {
            if $0.characterID != $1.characterID { return $0.characterID < $1.characterID }
            return (order[$0.actionID] ?? Int.max) < (order[$1.actionID] ?? Int.max)
        }
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
