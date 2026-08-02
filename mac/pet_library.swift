import Foundation

enum PetLibraryArchiveFilter: Sendable {
    case active
    case archived
    case all
}

enum PetLibraryCategoryFilter: Equatable, Sendable {
    case all
    case uncategorized
    case named(String)
}

enum PetLibraryDeleteTarget: Equatable, Sendable {
    case builtin(String)
    case legacyPrototype
    case custom(String)
}

enum PetLibraryDeletionError: LocalizedError, Equatable {
    case invalidCharacterID

    var errorDescription: String? {
        switch self {
        case .invalidCharacterID:
            return "The familiar ID is invalid and was not deleted."
        }
    }
}

/// The deletion bridge accepts only the three known bundled IDs, the legacy
/// prototype ID, or a canonical namespaced UUID. Keeping this policy outside
/// the WebKit handler makes the filesystem boundary independently testable.
enum PetLibraryDeletionPolicy {
    static let builtinIDs = ["lulu", "clawd", "nat"]

    static func target(for characterID: String) throws -> PetLibraryDeleteTarget {
        if builtinIDs.contains(characterID) { return .builtin(characterID) }
        if characterID == "prototype" { return .legacyPrototype }
        guard characterID.hasPrefix("custom:") else {
            throw PetLibraryDeletionError.invalidCharacterID
        }
        let suffix = String(characterID.dropFirst("custom:".count))
        guard let uuid = UUID(uuidString: suffix),
              suffix == uuid.uuidString.lowercased() else {
            throw PetLibraryDeletionError.invalidCharacterID
        }
        return .custom("custom:\(suffix)")
    }

    /// A bundled fallback always exists and never points back to the familiar
    /// being removed. The caller unarchives it before selection.
    static func safeBuiltinFallback(excluding characterID: String) -> String {
        builtinIDs.first(where: { $0 != characterID }) ?? "lulu"
    }
}

struct PetLibraryMetadata: Codable, Equatable, Sendable {
    var displayName: String? = nil
    var category: String?
    var archivedAt: Date?
    var lastUsedAt: Date?
}

enum PetLibraryStateError: LocalizedError, Equatable {
    case unsupportedSchema
    case invalidCharacterID
    case invalidDisplayName
    case invalidCategory
    case invalidDate
    case tooManyEntries
    case invalidPayload
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "The pet library schema is unsupported."
        case .invalidCharacterID: return "The pet library contains an invalid character ID."
        case .invalidDisplayName: return "The familiar name is invalid."
        case .invalidCategory: return "The pet library category is invalid."
        case .invalidDate: return "The pet library contains an invalid date."
        case .tooManyEntries: return "The pet library contains too many entries."
        case .invalidPayload: return "The saved pet library is invalid."
        case .payloadTooLarge: return "The saved pet library is too large."
        }
    }
}

/// User-owned metadata for built-in, legacy, and DIY familiars. Modern DIY
/// names are also mirrored to CustomPetStore so every surface stays in sync.
struct PetLibraryState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let recentLimit = 3
    static let maximumEntries = 1_024
    static let maximumDisplayNameCharacters = 28
    static let maximumDisplayNameBytes = 256
    static let maximumCategoryScalars = 40
    static let maximumCategoryBytes = 160

    private let schemaVersion: Int
    private var metadataByCharacterID: [String: PetLibraryMetadata]

    init() {
        schemaVersion = Self.schemaVersion
        metadataByCharacterID = [:]
    }

    func metadata(for characterID: String) -> PetLibraryMetadata? {
        metadataByCharacterID[characterID]
    }

    mutating func setDisplayName(_ displayName: String?,
                                 for characterID: String) throws {
        try Self.validateCharacterID(characterID)
        var metadata = metadataByCharacterID[characterID]
            ?? PetLibraryMetadata(category: nil, archivedAt: nil, lastUsedAt: nil)
        metadata.displayName = try displayName.map(Self.normalizedDisplayName)
        store(metadata, for: characterID)
    }

    mutating func setCategory(_ category: String?, for characterID: String) throws {
        try Self.validateCharacterID(characterID)
        var metadata = metadataByCharacterID[characterID]
            ?? PetLibraryMetadata(category: nil, archivedAt: nil, lastUsedAt: nil)
        metadata.category = try category.map(Self.normalizedCategory)
        store(metadata, for: characterID)
    }

    mutating func markUsed(_ characterID: String, at date: Date = Date()) throws {
        try Self.validateCharacterID(characterID)
        try Self.validate(date)
        var metadata = metadataByCharacterID[characterID]
            ?? PetLibraryMetadata(category: nil, archivedAt: nil, lastUsedAt: nil)
        metadata.lastUsedAt = date
        metadataByCharacterID[characterID] = metadata
    }

    mutating func archive(_ characterID: String, at date: Date = Date()) throws {
        try Self.validateCharacterID(characterID)
        try Self.validate(date)
        var metadata = metadataByCharacterID[characterID]
            ?? PetLibraryMetadata(category: nil, archivedAt: nil, lastUsedAt: nil)
        metadata.archivedAt = date
        metadataByCharacterID[characterID] = metadata
    }

    mutating func unarchive(_ characterID: String) throws {
        try Self.validateCharacterID(characterID)
        guard var metadata = metadataByCharacterID[characterID] else { return }
        metadata.archivedAt = nil
        store(metadata, for: characterID)
    }

    mutating func removeMetadata(for characterID: String) throws {
        try Self.validateCharacterID(characterID)
        metadataByCharacterID.removeValue(forKey: characterID)
    }

    func isArchived(_ characterID: String) -> Bool {
        metadataByCharacterID[characterID]?.archivedAt != nil
    }

    /// Active pets ordered by last use, then character ID. Never-used pets
    /// follow used pets in stable ID order so a new library still shows three.
    func recentCharacterIDs(validIDs: Set<String>) -> [String] {
        Array(libraryCharacterIDs(
            validIDs: validIDs, archive: .active,
            category: .all, expanded: false).prefix(Self.recentLimit))
    }

    /// Returns either the complete filtered library or its stable collapsed
    /// top three. Stale IDs in persisted metadata can never reappear unless the
    /// caller includes them in `validIDs`.
    func libraryCharacterIDs(validIDs: Set<String>,
                             archive: PetLibraryArchiveFilter = .active,
                             category: PetLibraryCategoryFilter = .all,
                             expanded: Bool = true) -> [String] {
        let normalizedCategory: String?
        switch category {
        case .named(let value):
            normalizedCategory = try? Self.normalizedCategory(value)
            if normalizedCategory == nil { return [] }
        default:
            normalizedCategory = nil
        }

        let filtered = validIDs.filter { characterID in
            guard Self.isValidCharacterID(characterID) else { return false }
            let metadata = metadataByCharacterID[characterID]
            switch archive {
            case .active where metadata?.archivedAt != nil: return false
            case .archived where metadata?.archivedAt == nil: return false
            default: break
            }
            switch category {
            case .all: return true
            case .uncategorized: return metadata?.category == nil
            case .named: return metadata?.category == normalizedCategory
            }
        }.sorted(by: recencyOrder)
        return expanded ? filtered : Array(filtered.prefix(Self.recentLimit))
    }

    func categories(validIDs: Set<String>,
                    archive: PetLibraryArchiveFilter = .active) -> [String] {
        let visible = Set(libraryCharacterIDs(
            validIDs: validIDs, archive: archive,
            category: .all, expanded: true))
        return Set(visible.compactMap { metadataByCharacterID[$0]?.category }).sorted()
    }

    func validated() throws -> PetLibraryState {
        guard schemaVersion == Self.schemaVersion else {
            throw PetLibraryStateError.unsupportedSchema
        }
        guard metadataByCharacterID.count <= Self.maximumEntries else {
            throw PetLibraryStateError.tooManyEntries
        }
        for (characterID, metadata) in metadataByCharacterID {
            try Self.validateCharacterID(characterID)
            if let category = metadata.category {
                guard category == (try Self.normalizedCategory(category)) else {
                    throw PetLibraryStateError.invalidCategory
                }
            }
            if let displayName = metadata.displayName {
                guard displayName == (try Self.normalizedDisplayName(displayName)) else {
                    throw PetLibraryStateError.invalidDisplayName
                }
            }
            if let date = metadata.archivedAt { try Self.validate(date) }
            if let date = metadata.lastUsedAt { try Self.validate(date) }
        }
        return self
    }

    private mutating func store(_ metadata: PetLibraryMetadata,
                                for characterID: String) {
        if metadata.displayName == nil && metadata.category == nil && metadata.archivedAt == nil
            && metadata.lastUsedAt == nil {
            metadataByCharacterID.removeValue(forKey: characterID)
        } else {
            metadataByCharacterID[characterID] = metadata
        }
    }

    private func recencyOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = metadataByCharacterID[lhs]?.lastUsedAt
        let right = metadataByCharacterID[rhs]?.lastUsedAt
        if left != right {
            if left == nil { return false }
            if right == nil { return true }
            return left! > right!
        }
        return lhs < rhs
    }

    private static func normalizedCategory(_ value: String) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= maximumCategoryScalars,
              normalized.utf8.count <= maximumCategoryBytes,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PetLibraryStateError.invalidCategory
        }
        return normalized
    }

    private static func normalizedDisplayName(_ value: String) throws -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= maximumDisplayNameCharacters,
              normalized.utf8.count <= maximumDisplayNameBytes,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PetLibraryStateError.invalidDisplayName
        }
        return normalized
    }

    private static func validateCharacterID(_ value: String) throws {
        guard isValidCharacterID(value) else {
            throw PetLibraryStateError.invalidCharacterID
        }
    }

    private static func isValidCharacterID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ":._-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw PetLibraryStateError.invalidDate
        }
    }
}

/// A bounded, atomic read-modify-write wrapper. Invalid saved data is reported
/// instead of being silently overwritten with an empty library.
final class PetLibraryStateStore: @unchecked Sendable {
    static let defaultKey = "mimo.petLibraryState.v1"
    static let maximumPayloadBytes = 256 * 1_024
    static let shared = PetLibraryStateStore()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> PetLibraryState {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    func save(_ state: PetLibraryState) throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(state)
    }

    @discardableResult
    func update(_ mutation: (inout PetLibraryState) throws -> Void) throws
        -> PetLibraryState {
        lock.lock(); defer { lock.unlock() }
        var state = try loadUnlocked()
        try mutation(&state)
        try saveUnlocked(state)
        return state
    }

    private func loadUnlocked() throws -> PetLibraryState {
        guard let object = defaults.object(forKey: key) else {
            return PetLibraryState()
        }
        guard let data = object as? Data else {
            throw PetLibraryStateError.invalidPayload
        }
        guard data.count <= Self.maximumPayloadBytes else {
            throw PetLibraryStateError.payloadTooLarge
        }
        do {
            return try JSONDecoder().decode(PetLibraryState.self, from: data)
                .validated()
        } catch let error as PetLibraryStateError {
            throw error
        } catch {
            throw PetLibraryStateError.invalidPayload
        }
    }

    private func saveUnlocked(_ state: PetLibraryState) throws {
        let validated = try state.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= Self.maximumPayloadBytes else {
            throw PetLibraryStateError.payloadTooLarge
        }
        defaults.set(data, forKey: key)
    }
}
