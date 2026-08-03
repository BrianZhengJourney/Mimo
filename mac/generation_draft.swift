// Mimo — recoverable generated-image drafts.
//
// Provider outputs are paid artifacts. Keep only those generated outputs (never
// the user's source photo) for a short local recovery window so a matte or
// layout validation error does not turn a successful API call into a black box.

import Foundation

enum FamiliarGenerationPhase: String, Codable, Sendable {
    case candidates
    case evolution
    case replacement
    case expressionSheet
}

enum FamiliarGenerationDraftStatus: String, Codable, Sendable {
    case received
    case processed
    case failedLocalProcessing
}

struct FamiliarGenerationDraftManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let requestID: String
    let phase: FamiliarGenerationPhase
    let quality: String
    let createdAt: Date
    let expiresAt: Date
    var status: FamiliarGenerationDraftStatus
    var rawAsset: String
    var processedAsset: String?
    var providerSeconds: Double?
    var localSeconds: Double?
    var failureMessage: String?
    var warnings: [String]
}

enum FamiliarGenerationDraftError: LocalizedError {
    case invalidRequestID
    case invalidPNG
    case missingDraft
    case corruptManifest
    case unsafePath
    case purgeIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidRequestID: return "The generation request ID is invalid."
        case .invalidPNG: return "The generated draft is not a valid PNG."
        case .missingDraft: return "The generated draft could not be found."
        case .corruptManifest: return "The generated draft metadata is corrupt."
        case .unsafePath: return "The generated draft path is unsafe."
        case .purgeIncomplete: return "Not all generated drafts could be deleted."
        }
    }
}

final class FamiliarGenerationDraftStore: @unchecked Sendable {
    static let folderName = "GenerationDrafts"
    static let manifestFilename = "manifest.json"
    static let rawFilename = "raw.png"
    static let processedFilename = "processed.png"
    static let maximumPNGBytes = 20 * 1024 * 1024
    static let maximumStoredBytes = 100 * 1024 * 1024
    static let retention: TimeInterval = 24 * 60 * 60

    private let fileManager: FileManager
    private let rootURL: URL
    private let draftsURL: URL
    private let lock = NSLock()

    init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        rootURL = root.standardizedFileURL
        draftsURL = root.standardizedFileURL.appendingPathComponent(Self.folderName, isDirectory: true)
        try? prepareStorage()
        try? purgeExpired()
    }

    var folderURL: URL { draftsURL }

    @discardableResult
    func saveRaw(requestID: String, pngData: Data, phase: FamiliarGenerationPhase,
                 quality: String, providerSeconds: Double?, now: Date = Date()) throws
        -> FamiliarGenerationDraftManifest {
        try synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: now)
            let canonical = try canonicalRequestID(requestID)
            try validatePNG(pngData)
            let destination = draftURL(canonical)
            guard !fileManager.fileExists(atPath: destination.path), isDescendant(destination, of: draftsURL) else {
                throw FamiliarGenerationDraftError.unsafePath
            }

            let temporary = draftsURL.appendingPathComponent(".install-\(canonical)-\(UUID().uuidString)",
                                                              isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            var cleanup = true
            defer { if cleanup { try? fileManager.removeItem(at: temporary) } }

            let manifest = FamiliarGenerationDraftManifest(
                schemaVersion: FamiliarGenerationDraftManifest.schemaVersion,
                requestID: canonical,
                phase: phase,
                quality: quality,
                createdAt: now,
                expiresAt: now.addingTimeInterval(Self.retention),
                status: .received,
                rawAsset: Self.rawFilename,
                processedAsset: nil,
                providerSeconds: providerSeconds,
                localSeconds: nil,
                failureMessage: nil,
                warnings: []
            )
            try pngData.write(to: temporary.appendingPathComponent(Self.rawFilename), options: [.atomic])
            try encode(manifest).write(to: temporary.appendingPathComponent(Self.manifestFilename), options: [.atomic])
            try fileManager.moveItem(at: temporary, to: destination)
            cleanup = false
            try enforceMaximumStorageLocked(preserving: requestID)
            return manifest
        }
    }

    @discardableResult
    func markProcessed(requestID: String, pngData: Data, localSeconds: Double,
                       warnings: [String] = []) throws -> FamiliarGenerationDraftManifest {
        try update(requestID: requestID) { directory, manifest in
            try validatePNG(pngData)
            try pngData.write(to: directory.appendingPathComponent(Self.processedFilename), options: [.atomic])
            manifest.status = .processed
            manifest.processedAsset = Self.processedFilename
            manifest.localSeconds = max(0, localSeconds)
            manifest.failureMessage = nil
            manifest.warnings = warnings
        }
    }

    @discardableResult
    func markLocalFailure(requestID: String, message: String, localSeconds: Double) throws
        -> FamiliarGenerationDraftManifest {
        try update(requestID: requestID) { _, manifest in
            manifest.status = .failedLocalProcessing
            manifest.localSeconds = max(0, localSeconds)
            manifest.failureMessage = String(message.prefix(500))
        }
    }

    func rawData(requestID: String) throws -> Data {
        try synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: Date())
            let canonical = try canonicalRequestID(requestID)
            let manifest = try loadManifest(canonical)
            let url = draftURL(canonical).appendingPathComponent(manifest.rawAsset)
            guard manifest.rawAsset == Self.rawFilename,
                  isSafeRegularFile(url, maximumBytes: Self.maximumPNGBytes),
                  isDescendant(url, of: draftsURL) else { throw FamiliarGenerationDraftError.unsafePath }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try validatePNG(data)
            return data
        }
    }

    func manifest(requestID: String) throws -> FamiliarGenerationDraftManifest {
        try synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: Date())
            return try loadManifest(canonicalRequestID(requestID))
        }
    }

    func recoverableDraftCount(now: Date = Date()) -> Int {
        (try? synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: now)
            return try fileManager.contentsOfDirectory(
                at: draftsURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { entry in
                guard UUID(uuidString: entry.lastPathComponent) != nil,
                      let manifest = try? loadManifest(entry.lastPathComponent) else { return false }
                return manifest.status == .received || manifest.status == .failedLocalProcessing
            }.count
        }) ?? 0
    }

    func delete(requestID: String) throws {
        try synchronized {
            try prepareStorage()
            let canonical = try canonicalRequestID(requestID)
            let directory = draftURL(canonical)
            guard fileManager.fileExists(atPath: directory.path) else { return }
            guard isSafeDirectory(directory), isDescendant(directory, of: draftsURL) else {
                throw FamiliarGenerationDraftError.unsafePath
            }
            _ = try loadManifest(canonical)
            let tombstone = draftsURL.appendingPathComponent(".delete-\(canonical)-\(UUID().uuidString)",
                                                              isDirectory: true)
            try fileManager.moveItem(at: directory, to: tombstone)
            try fileManager.removeItem(at: tombstone)
        }
    }

    func purgeExpired(now: Date = Date()) throws {
        try synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: now)
            try enforceMaximumStorageLocked()
        }
    }

    /// Privacy erasure needs stronger durability than routine retention
    /// pruning: every store-owned UUID draft (including interrupted install or
    /// delete tombstones) must be verified safe and removed with throwing I/O.
    /// Unrecognized entries are never followed or deleted.
    func purgeAll() throws {
        try synchronized {
            try prepareStorage()
            let entries = try fileManager.contentsOfDirectory(
                at: draftsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])
            for entry in entries where isManagedDraftEntryName(entry.lastPathComponent) {
                guard isSafeDirectory(entry), isDescendant(entry, of: draftsURL) else {
                    throw FamiliarGenerationDraftError.unsafePath
                }
                try fileManager.removeItem(at: entry)
            }
            let remaining = try fileManager.contentsOfDirectory(
                at: draftsURL, includingPropertiesForKeys: nil, options: [])
            guard !remaining.contains(where: {
                isManagedDraftEntryName($0.lastPathComponent)
            }) else {
                throw FamiliarGenerationDraftError.purgeIncomplete
            }
        }
    }

    private func update(requestID: String,
                        mutate: (URL, inout FamiliarGenerationDraftManifest) throws -> Void) throws
        -> FamiliarGenerationDraftManifest {
        try synchronized {
            try prepareStorage()
            try purgeExpiredLocked(now: Date())
            let canonical = try canonicalRequestID(requestID)
            let directory = draftURL(canonical)
            var manifest = try loadManifest(canonical)
            try mutate(directory, &manifest)
            try encode(manifest).write(to: directory.appendingPathComponent(Self.manifestFilename), options: [.atomic])
            return manifest
        }
    }

    private func loadManifest(_ requestID: String) throws -> FamiliarGenerationDraftManifest {
        let directory = draftURL(requestID)
        let url = directory.appendingPathComponent(Self.manifestFilename)
        guard isSafeDirectory(directory), isSafeRegularFile(url, maximumBytes: 64 * 1024),
              isDescendant(url, of: draftsURL),
              let data = try? Data(contentsOf: url) else {
            throw FamiliarGenerationDraftError.corruptManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(FamiliarGenerationDraftManifest.self, from: data),
              manifest.schemaVersion == FamiliarGenerationDraftManifest.schemaVersion,
              manifest.requestID == requestID,
              manifest.rawAsset == Self.rawFilename else {
            throw FamiliarGenerationDraftError.corruptManifest
        }
        return manifest
    }

    private func encode(_ manifest: FamiliarGenerationDraftManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private func prepareStorage() throws {
        try ensureDirectory(rootURL)
        guard isSafeDirectory(rootURL) else { throw FamiliarGenerationDraftError.unsafePath }
        try ensureDirectory(draftsURL)
        guard isSafeDirectory(draftsURL), isDescendant(draftsURL, of: rootURL) else {
            throw FamiliarGenerationDraftError.unsafePath
        }
        if let entries = try? fileManager.contentsOfDirectory(at: draftsURL,
                                                               includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent.hasPrefix(".install-")
                || entry.lastPathComponent.hasPrefix(".delete-") {
                try? fileManager.removeItem(at: entry)
            }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDraftsURL = draftsURL
        _ = try? mutableDraftsURL.setResourceValues(values)
    }

    private func purgeExpiredLocked(now: Date) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: draftsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let fallbackCutoff = now.addingTimeInterval(-Self.retention)
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            if let manifest = try? loadManifest(entry.lastPathComponent) {
                if manifest.expiresAt <= now { try? fileManager.removeItem(at: entry) }
                continue
            }
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if modified.map({ $0 <= fallbackCutoff }) ?? true {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// `preserving` is the request that just wrote, or is otherwise live.
    /// Records are evicted oldest-first, so without it the draft saved
    /// moments ago could be reclaimed between saveRaw and the caller reading
    /// it back — silently turning `outputRetained: true` into a missing file.
    /// The ledger's own prune already pins its active ID this way.
    private func enforceMaximumStorageLocked(preserving: String? = nil) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: draftsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        let pinned = preserving.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        var records: [(url: URL, date: Date, bytes: Int)] = entries.map { entry in
            let manifest = try? loadManifest(entry.lastPathComponent)
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let files = (try? fileManager.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            let bytes = files.reduce(into: 0) { total, file in
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            return (entry, manifest?.createdAt ?? modified ?? .distantPast, bytes)
        }
        var total = records.reduce(0) { $0 + $1.bytes }
        records.sort { $0.date < $1.date }
        for record in records where total > Self.maximumStoredBytes {
            guard record.url.lastPathComponent.lowercased() != pinned else { continue }
            try? fileManager.removeItem(at: record.url)
            total -= record.bytes
        }
    }

    private func canonicalRequestID(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value),
              value.caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw FamiliarGenerationDraftError.invalidRequestID
        }
        return uuid.uuidString.lowercased()
    }

    private func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value.caseInsensitiveCompare(uuid.uuidString) == .orderedSame
    }

    private func isManagedDraftEntryName(_ value: String) -> Bool {
        if isCanonicalUUID(value) { return true }
        for prefix in [".install-", ".delete-"] where value.hasPrefix(prefix) {
            let suffix = String(value.dropFirst(prefix.count))
            guard suffix.count == 73 else { return false }
            let first = String(suffix.prefix(36))
            let separator = suffix.index(suffix.startIndex, offsetBy: 36)
            let second = String(suffix[suffix.index(after: separator)...])
            return suffix[separator] == "-"
                && isCanonicalUUID(first) && isCanonicalUUID(second)
        }
        return false
    }

    private func draftURL(_ requestID: String) -> URL {
        draftsURL.appendingPathComponent(requestID.lowercased(), isDirectory: true)
    }

    private func validatePNG(_ data: Data) throws {
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard !data.isEmpty, data.count <= Self.maximumPNGBytes, data.starts(with: signature) else {
            throw FamiliarGenerationDraftError.invalidPNG
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw FamiliarGenerationDraftError.unsafePath }
            try fileManager.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: url.path)
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard !isSymlink(url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isSafeRegularFile(_ url: URL, maximumBytes: Int) -> Bool {
        guard !isSymlink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              let size = values.fileSize else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
            && (1...maximumBytes).contains(size)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let root = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
