// Mimo — persistent raster familiar assets.
//
// Generated sheets are normalized before they enter this store: three square
// 512 px frames (seed, bloom, radiant) packed left-to-right in one transparent
// 1536 × 512 PNG. User-provided paths and URLs never enter the manifest.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import WebKit

struct CustomPetTemperamentProfile: Equatable, Sendable {
    let id: String
    let promptFragment: String
    let motionID: String
    let accent: String
}

enum CustomPetTemperaments {
    static let fallbackID = "quiet-curious"

    static let profiles: [CustomPetTemperamentProfile] = [
        .init(
            id: "gentle-cozy",
            promptFragment: "Gentle and cozy: use a rounded, low-center silhouette, soft drooping details, a tiny reassuring smile, and calm welcoming body language.",
            motionID: "calm-breathe",
            accent: "#F0B8C9"
        ),
        .init(
            id: "quiet-curious",
            promptFragment: "Quiet and curious: use an attentive forward lean, alert ears or feelers, bright observant eyes, and one small detail that suggests careful exploration.",
            motionID: "curious-peek",
            accent: "#7DF0CF"
        ),
        .init(
            id: "bright-playful",
            promptFragment: "Bright and playful: use an energetic asymmetrical pose, a lifted paw or tail, a springy silhouette, and an open mischievous expression.",
            motionID: "playful-bounce",
            accent: "#FFD76B"
        ),
        .init(
            id: "brave-loyal",
            promptFragment: "Brave and loyal: use an upright stable stance, a strong readable silhouette, a small scarf or crest-like signature detail, and a dependable proud expression.",
            motionID: "proud-hop",
            accent: "#E89B61"
        ),
        .init(
            id: "dreamy-mysterious",
            promptFragment: "Dreamy and mysterious: use a flowing elongated silhouette, subtle moonlit or star-like details, a soft half-lidded expression, and weightless body language.",
            motionID: "dreamy-float",
            accent: "#B9A8FF"
        ),
        .init(
            id: "odd-whimsical",
            promptFragment: "Odd and whimsical: use one charmingly off-kilter feature, a surprising but coherent silhouette, a curious little grin, and endearing wobbling energy.",
            motionID: "whimsical-wobble",
            accent: "#E88FAE"
        ),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

    /// Product code can safely map persisted or incoming IDs to a stable
    /// profile. Unknown IDs deliberately fall back instead of becoming prompt
    /// text supplied by the WebView.
    static func profile(for id: String?) -> CustomPetTemperamentProfile {
        byID[id ?? ""] ?? byID[fallbackID]!
    }

    static func supportedProfile(for id: String) -> CustomPetTemperamentProfile? {
        byID[id]
    }
}

struct CustomPetManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let id: String
    let name: String
    let temperamentID: String
    let accent: String
    let asset: String
    /// Evolution-stage indices (0…2) that have an installed expression sheet
    /// (`expr-<index>.png`). Absent in legacy v2 manifests.
    let expressions: [Int]?
    /// Action name ("walk") → strip filename (`action-walk.png`), a horizontal
    /// run of square 512px cells whose frames a behaviour pack may drive.
    /// Absent on familiars generated before action sheets existed.
    let actions: [String: String]?
}

struct CustomPetRuntimeSpec: Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let id: String
    let characterID: String
    let name: String
    let temperamentID: String
    let accent: String
    let assetURL: String
    let motionProfile: String
    /// Stage index ("0"…"2") → asset URL for that stage's expression sheet.
    let expressionURLs: [String: String]
    /// Action name ("walk") → asset URL for that action's frame strip.
    let actionURLs: [String: String]

    var dictionary: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "kind": kind,
            "id": id,
            "characterID": characterID,
            "name": name,
            "temperamentID": temperamentID,
            "accent": accent,
            "assetURL": assetURL,
            "motionProfile": motionProfile,
            "expressionURLs": expressionURLs,
            "actionURLs": actionURLs,
        ]
    }
}

enum CustomPetStoreError: LocalizedError {
    case invalidName
    case unsupportedTemperament
    case invalidAccent
    case invalidPNG
    case invalidSheetDimensions
    case missingTransparency
    case emptyFrame(Int)
    case duplicateID
    case invalidCustomID
    case missingPet
    case corruptManifest
    case unsafeAssetPath
    case invalidExpressionStage
    case invalidActionName
    case invalidActionStrip

    var errorDescription: String? {
        switch self {
        case .invalidName: return "The familiar name is invalid."
        case .unsupportedTemperament: return "The familiar temperament is not supported."
        case .invalidAccent: return "The familiar accent color is invalid."
        case .invalidPNG: return "The familiar sheet is not a valid PNG."
        case .invalidSheetDimensions: return "The familiar sheet must be exactly 1536 × 512 pixels."
        case .missingTransparency: return "The familiar sheet needs a transparent padded background."
        case .emptyFrame(let index): return "Familiar form \(index + 1) is empty."
        case .duplicateID: return "A familiar with this ID already exists."
        case .invalidCustomID: return "Only custom familiar IDs can be deleted."
        case .missingPet: return "The custom familiar could not be found."
        case .corruptManifest: return "The custom familiar manifest is invalid."
        case .unsafeAssetPath: return "The custom familiar asset path is unsafe."
        case .invalidExpressionStage: return "The expression sheet stage index is invalid."
        case .invalidActionName: return "The action name is invalid."
        case .invalidActionStrip: return "The action strip must be square 512px cells in a horizontal row."
        }
    }
}

final class CustomPetStore: @unchecked Sendable {
    static let schemaVersion = 3
    /// v2 manifests (no expression sheets) remain fully readable.
    static let legacySchemaVersions: Set<Int> = [2]
    static let kind = "raster-sheet"
    static let characterPrefix = "custom:"
    static let scheme = "mimo-pet"
    static let schemeHost = "asset"
    static let assetRevision = "4"
    static let sheetFilename = "sheet.png"
    static let manifestFilename = "manifest.json"
    static let expressionStageCount = 3

    static func expressionFilename(stageIndex: Int) -> String {
        "expr-\(stageIndex).png"
    }

    static func actionFilename(_ name: String) -> String { "action-\(name).png" }
    /// Lowercase ASCII words only — the name lands in filenames and URLs.
    static func isActionName(_ name: String) -> Bool {
        (1...24).contains(name.count)
            && name.allSatisfy { ("a"..."z").contains($0) }
    }
    /// Cell edge of an action strip, and the frame counts worth storing —
    /// one 4x4 sheet yields at most 16, and a 1-frame "animation" is a bug.
    static let actionCellSize = 512
    static let actionFrameRange = 2...16
    static let sheetWidth = 1536
    static let sheetHeight = 512
    static let frameWidth = 512
    static let maximumPNGBytes = 16 * 1024 * 1024
    static let maximumManifestBytes = 64 * 1024

    private let fileManager: FileManager
    private let rootURL: URL
    private let petsURL: URL
    private let lock = NSLock()

    /// Construction is deliberately non-throwing so malformed local storage
    /// can never crash app launch. Every operation revalidates the root and
    /// reports a recoverable error to its caller.
    init(root: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = root.standardizedFileURL
        self.petsURL = root.standardizedFileURL.appendingPathComponent("Pets", isDirectory: true)
        if (try? ensureStorageReady()) != nil { cleanupStaleTransactions() }
    }

    /// Installs an already-normalized three-frame PNG atomically and returns
    /// the exact runtime dictionary consumed by Settings and the overlay.
    @discardableResult
    func install(pngData: Data, name: String, temperamentID: String,
                 accent: String, id: UUID = UUID()) throws -> [String: Any] {
        try synchronized {
            try ensureStorageReady()
            try validateName(name)
            guard CustomPetTemperaments.supportedProfile(for: temperamentID) != nil else {
                throw CustomPetStoreError.unsupportedTemperament
            }
            guard Self.isAccent(accent) else { throw CustomPetStoreError.invalidAccent }
            let sanitizedPNGData = try CharacterSheetProcessor.sanitizeNormalizedSheet(
                pngData: pngData)
            try Self.validateNormalizedPNG(sanitizedPNGData)

            let idString = Self.canonical(id)
            let destination = petDirectory(idString)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw CustomPetStoreError.duplicateID
            }
            guard Self.isDescendant(destination, of: petsURL) else {
                throw CustomPetStoreError.unsafeAssetPath
            }

            let temporary = petsURL.appendingPathComponent(".install-\(idString)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            var shouldRemoveTemporary = true
            defer {
                if shouldRemoveTemporary { try? fileManager.removeItem(at: temporary) }
            }

            let manifest = CustomPetManifest(
                schemaVersion: Self.schemaVersion,
                kind: Self.kind,
                id: idString,
                name: name,
                temperamentID: temperamentID,
                accent: accent.uppercased(),
                asset: Self.sheetFilename,
                expressions: [],
                actions: nil
            )
            let manifestData = try Self.encodeManifest(manifest)

            let sheetURL = temporary.appendingPathComponent(Self.sheetFilename, isDirectory: false)
            let manifestURL = temporary.appendingPathComponent(Self.manifestFilename, isDirectory: false)
            try sanitizedPNGData.write(to: sheetURL, options: [.atomic])
            try manifestData.write(to: manifestURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sheetURL.path)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

            try fileManager.moveItem(at: temporary, to: destination)
            shouldRemoveTemporary = false
            return runtimeSpec(for: manifest).dictionary
        }
    }

    /// Installs (or replaces) one stage's expression sheet — a normalized
    /// 1536 × 512 PNG whose three frames are NEUTRAL / JOY / REST of that
    /// stage's design. Optional: a familiar without expression sheets keeps
    /// the exact pre-expression behavior.
    @discardableResult
    func installExpressionSheet(characterID: String, stageIndex: Int,
                                pngData: Data) throws -> [String: Any] {
        try synchronized {
            try ensureStorageReady()
            guard (0..<Self.expressionStageCount).contains(stageIndex) else {
                throw CustomPetStoreError.invalidExpressionStage
            }
            let uuidString = try Self.uuidString(fromCharacterID: characterID)
            let manifest = try loadManifest(uuidString: uuidString)
            let sanitized = try CharacterSheetProcessor.sanitizeNormalizedSheet(pngData: pngData)
            try Self.validateNormalizedPNG(sanitized)

            let directory = petDirectory(uuidString)
            let expressionURL = directory.appendingPathComponent(
                Self.expressionFilename(stageIndex: stageIndex), isDirectory: false)
            guard Self.isDescendant(expressionURL, of: petsURL) else {
                throw CustomPetStoreError.unsafeAssetPath
            }
            try sanitized.write(to: expressionURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: expressionURL.path)

            let indices = Set(manifest.expressions ?? []).union([stageIndex]).sorted()
            let updated = CustomPetManifest(
                schemaVersion: Self.schemaVersion,
                kind: manifest.kind,
                id: manifest.id,
                name: manifest.name,
                temperamentID: manifest.temperamentID,
                accent: manifest.accent,
                asset: manifest.asset,
                expressions: indices,
                actions: manifest.actions
            )
            let manifestURL = directory.appendingPathComponent(Self.manifestFilename,
                                                               isDirectory: false)
            try Self.encodeManifest(updated).write(to: manifestURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: manifestURL.path)
            return runtimeSpec(for: updated).dictionary
        }
    }

    /// Installs (or replaces) one action's frame strip — a horizontal run of
    /// square 512px cells produced by the action-sheet pipeline, whose frames
    /// a behaviour pack may drive. Optional: a familiar without action strips
    /// keeps the exact procedural-motion behavior.
    @discardableResult
    func installActionStrip(characterID: String, action: String,
                            pngData: Data) throws -> [String: Any] {
        try synchronized {
            try ensureStorageReady()
            guard Self.isActionName(action) else {
                throw CustomPetStoreError.invalidActionName
            }
            guard pngData.count <= Self.maximumPNGBytes,
                  let dimensions = CharacterSheetProcessor.pngPixelDimensions(pngData),
                  dimensions.height == Self.actionCellSize,
                  dimensions.width % Self.actionCellSize == 0,
                  Self.actionFrameRange.contains(dimensions.width / Self.actionCellSize) else {
                throw CustomPetStoreError.invalidActionStrip
            }
            let uuidString = try Self.uuidString(fromCharacterID: characterID)
            let manifest = try loadManifest(uuidString: uuidString)

            let directory = petDirectory(uuidString)
            let filename = Self.actionFilename(action)
            let stripURL = directory.appendingPathComponent(filename, isDirectory: false)
            guard Self.isDescendant(stripURL, of: petsURL) else {
                throw CustomPetStoreError.unsafeAssetPath
            }
            try pngData.write(to: stripURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: stripURL.path)

            var actions = manifest.actions ?? [:]
            actions[action] = filename
            let updated = CustomPetManifest(
                schemaVersion: Self.schemaVersion,
                kind: manifest.kind,
                id: manifest.id,
                name: manifest.name,
                temperamentID: manifest.temperamentID,
                accent: manifest.accent,
                asset: manifest.asset,
                expressions: manifest.expressions,
                actions: actions
            )
            let manifestURL = directory.appendingPathComponent(Self.manifestFilename,
                                                               isDirectory: false)
            try Self.encodeManifest(updated).write(to: manifestURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: manifestURL.path)
            return runtimeSpec(for: updated).dictionary
        }
    }

    private static func encodeManifest(_ manifest: CustomPetManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    /// Invalid or incomplete pet directories are ignored so one interrupted
    /// install cannot prevent the rest of Settings from loading.
    func listRuntimeSpecs() throws -> [[String: Any]] {
        try synchronized {
            try ensureStorageReady()
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
            let entries = try fileManager.contentsOfDirectory(
                at: petsURL, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            let specs = entries.compactMap { entry -> CustomPetRuntimeSpec? in
                guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isDirectory == true, values.isSymbolicLink != true,
                      UUID(uuidString: entry.lastPathComponent) != nil,
                      Self.isDescendant(entry, of: petsURL) else { return nil }
                return try? loadRuntimeSpec(uuidString: entry.lastPathComponent)
            }
            return specs.sorted { lhs, rhs in
                let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }.map(\.dictionary)
        }
    }

    /// Resolves one custom familiar without scanning every stored asset. Used
    /// by selection and deletion paths where only one ID needs validation.
    func runtimeSpec(characterID: String) throws -> [String: Any] {
        try synchronized {
            try ensureStorageReady()
            let uuidString = try Self.uuidString(fromCharacterID: characterID)
            return try loadRuntimeSpec(uuidString: uuidString).dictionary
        }
    }

    /// Only namespaced IDs returned by this store are accepted. Built-ins,
    /// raw UUIDs, paths, and URL strings cannot reach FileManager deletion.
    func delete(characterID: String) throws {
        try synchronized {
            try ensureStorageReady()
            let uuidString = try Self.uuidString(fromCharacterID: characterID)
            let directory = petDirectory(uuidString)
            guard fileManager.fileExists(atPath: directory.path) else {
                throw CustomPetStoreError.missingPet
            }
            guard Self.isSafeDirectory(directory, fileManager: fileManager),
                  Self.isDescendant(directory, of: petsURL) else {
                throw CustomPetStoreError.unsafeAssetPath
            }
            // A valid manifest proves this UUID directory belongs to the store.
            _ = try loadManifest(uuidString: uuidString)
            let tombstone = petsURL.appendingPathComponent(
                ".delete-\(uuidString)-\(UUID().uuidString)", isDirectory: true
            )
            try fileManager.moveItem(at: directory, to: tombstone)
            do {
                try fileManager.removeItem(at: tombstone)
            } catch {
                // Restore visibility if cleanup fails after the atomic rename.
                if !fileManager.fileExists(atPath: directory.path) {
                    try? fileManager.moveItem(at: tombstone, to: directory)
                }
                throw error
            }
        }
    }

    /// Strictly resolves one of this store's custom-scheme URLs. This method is
    /// shared by the WebKit handler and tests; no caller can request a path.
    func assetData(for url: URL) throws -> Data {
        try synchronized {
            try ensureStorageReady()
            let location = try Self.assetLocation(fromAssetURL: url)
            let manifest = try loadManifest(uuidString: location.uuidString)
            let fileURL = petDirectory(location.uuidString)
                .appendingPathComponent(location.filename, isDirectory: false)
            guard Self.isDescendant(fileURL, of: petsURL) else {
                throw CustomPetStoreError.unsafeAssetPath
            }
            if let action = location.actionName {
                guard (manifest.actions ?? [:])[action] == location.filename else {
                    throw CustomPetStoreError.unsafeAssetPath
                }
                // Strips are not stage sheets: different dimensions, and the
                // three-stage sanitizer would reject them outright.
                guard Self.isSafeRegularFile(fileURL, maximumBytes: Self.maximumPNGBytes,
                                             fileManager: fileManager) else {
                    throw CustomPetStoreError.unsafeAssetPath
                }
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                guard let dimensions = CharacterSheetProcessor.pngPixelDimensions(data),
                      dimensions.height == Self.actionCellSize,
                      dimensions.width % Self.actionCellSize == 0,
                      Self.actionFrameRange.contains(dimensions.width / Self.actionCellSize) else {
                    throw CustomPetStoreError.invalidActionStrip
                }
                return data
            }
            if let stageIndex = location.expressionStageIndex {
                guard (manifest.expressions ?? []).contains(stageIndex) else {
                    throw CustomPetStoreError.unsafeAssetPath
                }
            } else {
                guard manifest.asset == Self.sheetFilename else {
                    throw CustomPetStoreError.unsafeAssetPath
                }
            }
            return try sanitizedSheetData(at: fileURL)
        }
    }

    private func loadRuntimeSpec(uuidString: String) throws -> CustomPetRuntimeSpec {
        let manifest = try loadManifest(uuidString: uuidString)
        let sheetURL = petDirectory(manifest.id).appendingPathComponent(Self.sheetFilename)
        guard Self.isSafeRegularFile(sheetURL, maximumBytes: Self.maximumPNGBytes, fileManager: fileManager),
              Self.isDescendant(sheetURL, of: petsURL) else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        try verifySheetIsLoadable(at: sheetURL)
        return runtimeSpec(for: manifest)
    }

    /// Path and container checks only — no rasterization.
    ///
    /// `validateNormalizedPNG` decodes a 1536x512 sheet and scans 786k pixels.
    /// Running that per pet on every `pushSettingsState` (which fires on every
    /// Settings open, language change, and expression-sheet completion) and per
    /// `mimo-pet://` asset request meant seconds of main-thread work for a
    /// property the install path already guaranteed. The cheap check is what
    /// the code comment at `validatePNGMetadata` always said belonged here.
    private func verifySheetIsLoadable(at sheetURL: URL) throws {
        guard Self.isSafeRegularFile(sheetURL, maximumBytes: Self.maximumPNGBytes,
                                     fileManager: fileManager),
              Self.isDescendant(sheetURL, of: petsURL) else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        let data = try Data(contentsOf: sheetURL, options: [.mappedIfSafe])
        try Self.validatePNGMetadata(data)
    }

    /// Bytes to hand the WebView. Sanitizes for rendering but never writes:
    /// a read path that mutates persistent state turned a transient IO error
    /// into a broken image, and rewrote multi-megabyte files from inside the
    /// store lock on the main thread. Persisting the repair is
    /// `repairStoredSheets()`'s job.
    private func sanitizedSheetData(at sheetURL: URL) throws -> Data {
        guard Self.isSafeRegularFile(sheetURL, maximumBytes: Self.maximumPNGBytes,
                                     fileManager: fileManager),
              Self.isDescendant(sheetURL, of: petsURL) else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        let data = try Data(contentsOf: sheetURL, options: [.mappedIfSafe])
        let sanitized = try CharacterSheetProcessor.sanitizeNormalizedSheet(pngData: data)
        try Self.validatePNGMetadata(sanitized)
        return sanitized
    }

    /// One-shot repair of sheets written before the install path sanitized
    /// them. Explicit and off the hot paths, rather than a hidden side effect
    /// of every image load. Safe to call from a background queue.
    func repairStoredSheets() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: petsURL, includingPropertiesForKeys: nil) else { return }
        for directory in entries {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for sheetURL in files where sheetURL.pathExtension == "png" {
                guard Self.isSafeRegularFile(sheetURL, maximumBytes: Self.maximumPNGBytes,
                                             fileManager: fileManager),
                      Self.isDescendant(sheetURL, of: petsURL),
                      let data = try? Data(contentsOf: sheetURL, options: [.mappedIfSafe]),
                      let sanitized = try? CharacterSheetProcessor.sanitizeNormalizedSheet(pngData: data),
                      sanitized != data,
                      (try? Self.validateNormalizedPNG(sanitized)) != nil else { continue }
                try? sanitized.write(to: sheetURL, options: [.atomic])
                try? fileManager.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: sheetURL.path)
            }
        }
    }

    private func loadManifest(uuidString: String) throws -> CustomPetManifest {
        guard let uuid = UUID(uuidString: uuidString) else {
            throw CustomPetStoreError.corruptManifest
        }
        let canonicalID = Self.canonical(uuid)
        let directory = petDirectory(canonicalID)
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
        guard Self.isSafeDirectory(directory, fileManager: fileManager),
              Self.isSafeRegularFile(manifestURL, maximumBytes: Self.maximumManifestBytes, fileManager: fileManager),
              Self.isDescendant(manifestURL, of: petsURL),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CustomPetManifest.self, from: data),
              manifest.schemaVersion == Self.schemaVersion
                  || Self.legacySchemaVersions.contains(manifest.schemaVersion),
              manifest.kind == Self.kind,
              manifest.id == canonicalID,
              manifest.asset == Self.sheetFilename,
              (try? validateName(manifest.name)) != nil,
              CustomPetTemperaments.supportedProfile(for: manifest.temperamentID) != nil,
              Self.isAccent(manifest.accent) else {
            throw CustomPetStoreError.corruptManifest
        }
        if let expressions = manifest.expressions {
            guard Set(expressions).count == expressions.count,
                  expressions.allSatisfy({ (0..<Self.expressionStageCount).contains($0) }) else {
                throw CustomPetStoreError.corruptManifest
            }
        }
        return manifest
    }

    private func runtimeSpec(for manifest: CustomPetManifest) -> CustomPetRuntimeSpec {
        let profile = CustomPetTemperaments.profile(for: manifest.temperamentID)
        // Only advertise expression sheets whose file is actually present and
        // sane, so a half-written asset can never break the overlay.
        var expressionURLs: [String: String] = [:]
        for stageIndex in manifest.expressions ?? [] {
            let filename = Self.expressionFilename(stageIndex: stageIndex)
            let fileURL = petDirectory(manifest.id).appendingPathComponent(filename,
                                                                           isDirectory: false)
            guard Self.isSafeRegularFile(fileURL, maximumBytes: Self.maximumPNGBytes,
                                         fileManager: fileManager),
                  Self.isDescendant(fileURL, of: petsURL) else { continue }
            expressionURLs[String(stageIndex)] =
                "\(Self.scheme)://\(Self.schemeHost)/\(manifest.id)/\(filename)?v=\(Self.assetRevision)"
        }
        // Same present-and-sane rule as expressions: only advertise strips
        // whose file is actually there.
        var actionURLs: [String: String] = [:]
        for (action, filename) in manifest.actions ?? [:] {
            guard Self.isActionName(action), Self.actionFilename(action) == filename else { continue }
            let fileURL = petDirectory(manifest.id).appendingPathComponent(filename,
                                                                           isDirectory: false)
            guard Self.isSafeRegularFile(fileURL, maximumBytes: Self.maximumPNGBytes,
                                         fileManager: fileManager),
                  Self.isDescendant(fileURL, of: petsURL) else { continue }
            actionURLs[action] =
                "\(Self.scheme)://\(Self.schemeHost)/\(manifest.id)/\(filename)?v=\(Self.assetRevision)"
        }
        return CustomPetRuntimeSpec(
            // The manifest's own version, not the current one. Hardcoding
            // Self.schemaVersion advertised a v2 pet as v3 with empty
            // expressionURLs — indistinguishable from a v3 pet that simply has
            // no expression sheets, and no record of what was ever migrated.
            schemaVersion: manifest.schemaVersion,
            kind: Self.kind,
            id: manifest.id,
            characterID: Self.characterPrefix + manifest.id,
            name: manifest.name,
            temperamentID: manifest.temperamentID,
            accent: manifest.accent,
            assetURL: "\(Self.scheme)://\(Self.schemeHost)/\(manifest.id)/\(Self.sheetFilename)?v=\(Self.assetRevision)",
            motionProfile: profile.motionID,
            expressionURLs: expressionURLs,
            actionURLs: actionURLs
        )
    }

    private func petDirectory(_ uuidString: String) -> URL {
        petsURL.appendingPathComponent(uuidString.lowercased(), isDirectory: true)
    }

    private func validateName(_ name: String) throws {
        guard (1...60).contains(name.count),
              name.trimmingCharacters(in: .whitespacesAndNewlines).count > 0,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CustomPetStoreError.invalidName
        }
    }

    private func ensureStorageReady() throws {
        try Self.ensureDirectory(rootURL, fileManager: fileManager)
        // Validate the injected root before creating anything below it. This
        // prevents a root swapped to a symlink from redirecting writes.
        guard Self.isSafeDirectory(rootURL, fileManager: fileManager) else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        try Self.ensureDirectory(petsURL, fileManager: fileManager)
        guard Self.isSafeDirectory(petsURL, fileManager: fileManager),
              Self.isDescendant(petsURL, of: rootURL) else {
            throw CustomPetStoreError.unsafeAssetPath
        }
    }

    private func cleanupStaleTransactions() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: petsURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".install-") || name.hasPrefix(".delete-") else { continue }
            // entries comes from a direct directory listing; removeItem unlinks
            // a symlink itself rather than following it.
            try? fileManager.removeItem(at: entry)
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func canonical(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    private static func uuidString(fromCharacterID characterID: String) throws -> String {
        guard characterID.hasPrefix(characterPrefix) else {
            throw CustomPetStoreError.invalidCustomID
        }
        let suffix = String(characterID.dropFirst(characterPrefix.count))
        guard !suffix.isEmpty, let uuid = UUID(uuidString: suffix),
              suffix.caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw CustomPetStoreError.invalidCustomID
        }
        return canonical(uuid)
    }

    struct AssetLocation {
        let uuidString: String
        let filename: String
        /// Non-nil when the URL names an expression sheet instead of sheet.png.
        let expressionStageIndex: Int?
        /// Non-nil when the URL names an action strip (`action-<name>.png`).
        let actionName: String?
    }

    static func assetLocation(fromAssetURL url: URL) throws -> AssetLocation {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == schemeHost,
              components.user == nil, components.password == nil, components.port == nil,
              components.percentEncodedQuery == "v=\(assetRevision)", components.fragment == nil,
              !components.percentEncodedPath.contains("%") else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        let path = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2,
              let uuid = UUID(uuidString: String(path[0])),
              String(path[0]).caseInsensitiveCompare(uuid.uuidString) == .orderedSame else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        let filename = String(path[1])
        var stageIndex: Int?
        var actionName: String?
        if filename != sheetFilename {
            if let match = (0..<expressionStageCount).first(where: {
                expressionFilename(stageIndex: $0) == filename
            }) {
                stageIndex = match
            } else if filename.hasPrefix("action-"), filename.hasSuffix(".png"),
                      case let name = String(filename.dropFirst("action-".count).dropLast(".png".count)),
                      isActionName(name), actionFilename(name) == filename {
                actionName = name
            } else {
                throw CustomPetStoreError.unsafeAssetPath
            }
        }
        guard components.percentEncodedPath == "/\(canonical(uuid))/\(filename)" else {
            throw CustomPetStoreError.unsafeAssetPath
        }
        return AssetLocation(uuidString: canonical(uuid), filename: filename,
                             expressionStageIndex: stageIndex, actionName: actionName)
    }

    private static func isAccent(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }

    private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CustomPetStoreError.unsafeAssetPath }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    private static func isSafeDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isSafeRegularFile(_ url: URL, maximumBytes: Int,
                                          fileManager: FileManager) -> Bool {
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return false
        }
        guard let size = values.fileSize else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true && (1...maximumBytes).contains(size)
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let root = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root + "/")
    }

    private static func validateNormalizedPNG(_ data: Data) throws {
        try validatePNGMetadata(data)
        guard !data.isEmpty, data.count <= maximumPNGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CustomPetStoreError.invalidPNG
        }
        guard [.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo) else {
            throw CustomPetStoreError.missingTransparency
        }

        let bytesPerRow = sheetWidth * 4
        // Owned explicitly because the alpha scan below reads it back after
        // draw(). `&pixels` on a local Array only guarantees the pointer for
        // the duration of the CGContext call, while the context keeps writing
        // through it — undefined behaviour that happened to work.
        let byteCount = bytesPerRow * sheetHeight
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pixels.initialize(repeating: 0, count: byteCount)
        defer { pixels.deinitialize(count: byteCount); pixels.deallocate() }
        guard let context = CGContext(
            data: pixels,
            width: sheetWidth,
            height: sheetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CustomPetStoreError.invalidPNG
        }
        context.clear(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        context.draw(image, in: CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))

        // A normalized frame reserves an 8 px transparent border and contains
        // enough foreground pixels to be a real form, not a blank/corrupt cell.
        for frame in 0..<3 {
            let minX = frame * frameWidth
            var foregroundCount = 0
            var opaqueBorder = false
            for y in 0..<sheetHeight {
                for localX in 0..<frameWidth {
                    let alpha = pixels[y * bytesPerRow + (minX + localX) * 4 + 3]
                    if alpha > 24 { foregroundCount += 1 }
                    if alpha > 8 && (localX < 8 || localX >= frameWidth - 8 || y < 8 || y >= sheetHeight - 8) {
                        opaqueBorder = true
                    }
                }
            }
            guard foregroundCount >= 64 else { throw CustomPetStoreError.emptyFrame(frame) }
            guard !opaqueBorder else { throw CustomPetStoreError.missingTransparency }
        }
    }

    /// Cheap persisted-asset validation: ImageIO reads container properties
    /// without rasterizing and scanning all 786k pixels. Full alpha/frame
    /// validation remains mandatory at install time.
    private static func validatePNGMetadata(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumPNGBytes,
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw CustomPetStoreError.invalidPNG
        }
        guard width.intValue == sheetWidth, height.intValue == sheetHeight else {
            throw CustomPetStoreError.invalidSheetDimensions
        }
        guard (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue == true else {
            throw CustomPetStoreError.missingTransparency
        }
    }
}

/// Serves only `mimo-pet://asset/<UUID>/sheet.png` from CustomPetStore. The
/// URL is parsed into a UUID, never joined to the filesystem as a path.
final class CustomPetAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: CustomPetStore

    init(store: CustomPetStore) {
        self.store = store
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        serve(urlSchemeTask)
    }

    /// Kept as an internal seam so URL validation and response behavior can be
    /// tested without launching a WebKit content process.
    func serve(_ urlSchemeTask: WKURLSchemeTask) {
        do {
            let method = (urlSchemeTask.request.httpMethod ?? "GET").uppercased()
            guard method == "GET" || method == "HEAD",
                  let url = urlSchemeTask.request.url else {
                throw CustomPetStoreError.unsafeAssetPath
            }
            let data = try store.assetData(for: url)
            let response = URLResponse(
                url: url,
                mimeType: "image/png",
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            if method == "GET" { urlSchemeTask.didReceive(data) }
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Reads are bounded local files and complete synchronously in start().
    }
}
