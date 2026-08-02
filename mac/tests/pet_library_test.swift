// sources: pet_library.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) {
    do {
        try body()
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    } catch {}
}

@main
struct PetLibraryTests {
    static func main() throws {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = PetLibraryState()
        try state.setDisplayName("  米墨  ", for: "lulu")
        try state.setCategory("  Work friends  ", for: "custom:alpha")
        try state.markUsed("custom:alpha", at: base.addingTimeInterval(20))
        try state.markUsed("lulu", at: base.addingTimeInterval(30))
        try state.markUsed("custom:beta", at: base.addingTimeInterval(20))
        try state.markUsed("custom:gamma", at: base.addingTimeInterval(10))
        try state.markUsed("custom:stale", at: base.addingTimeInterval(100))

        let valid: Set<String> = [
            "lulu", "custom:alpha", "custom:beta", "custom:gamma", "nat",
        ]
        expect(state.metadata(for: "custom:alpha")?.category == "Work friends",
               "categories should be normalized without changing user text")
        expect(state.metadata(for: "lulu")?.displayName == "米墨",
               "built-in familiar aliases should be normalized and persisted")
        expect(state.recentCharacterIDs(validIDs: valid)
            == ["lulu", "custom:alpha", "custom:beta"],
               "recent top three should ignore stale IDs and break date ties by ID")
        expect(state.libraryCharacterIDs(validIDs: valid, expanded: false).count == 3,
               "collapsed library should contain exactly the recent limit")
        expect(state.libraryCharacterIDs(validIDs: valid, expanded: true)
            == ["lulu", "custom:alpha", "custom:beta", "custom:gamma", "nat"],
               "expanded library should include never-used valid pets after recent pets")

        try state.setCategory("Friends", for: "custom:beta")
        try state.setCategory("Friends", for: "custom:gamma")
        expect(state.libraryCharacterIDs(
            validIDs: valid, category: .named(" Friends "), expanded: true)
            == ["custom:beta", "custom:gamma"],
               "named category filtering should use normalized user filing names")
        expect(state.libraryCharacterIDs(
            validIDs: valid, category: .uncategorized, expanded: true)
            == ["lulu", "nat"],
               "uncategorized filtering should exclude filed pets")
        expect(state.categories(validIDs: valid) == ["Friends", "Work friends"],
               "category names should be unique and deterministic")

        try state.archive("custom:beta", at: base.addingTimeInterval(40))
        expect(state.isArchived("custom:beta"), "archive should set reversible metadata")
        expect(!state.recentCharacterIDs(validIDs: valid).contains("custom:beta"),
               "archived pets should leave the active recent list")
        expect(state.libraryCharacterIDs(
            validIDs: valid, archive: .archived, expanded: true) == ["custom:beta"],
               "archive filtering should expose archived pets explicitly")
        expect(state.metadata(for: "custom:beta")?.category == "Friends",
               "archiving should preserve category metadata")
        try state.unarchive("custom:beta")
        expect(!state.isArchived("custom:beta"), "unarchive should restore visibility")
        expect(state.metadata(for: "custom:beta")?.lastUsedAt
            == base.addingTimeInterval(20),
               "unarchive should preserve recency metadata")

        expectThrows("control characters must not enter a category") {
            try state.setCategory("bad\u{0000}name", for: "custom:alpha")
        }
        expectThrows("control characters must not enter a familiar name") {
            try state.setDisplayName("bad\u{0000}name", for: "lulu")
        }
        expectThrows("familiar names must stay compact") {
            try state.setDisplayName(String(repeating: "a", count: 29), for: "lulu")
        }
        expectThrows("paths must not enter the character index") {
            try state.markUsed("../Pets/alpha", at: base)
        }
        expect(state.libraryCharacterIDs(
            validIDs: ["valid", "bad id"], expanded: true) == ["valid"],
               "invalid caller IDs should never enter a rendered library")

        let suite = "Mimo.PetLibraryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PetLibraryStateStore(defaults: defaults)
        try store.save(state)
        let loaded = try store.load()
        expect(loaded == state, "UserDefaults storage should round-trip")
        let updated = try store.update {
            try $0.archive("custom:alpha", at: base.addingTimeInterval(50))
        }
        let reloaded = try store.load()
        expect(updated.isArchived("custom:alpha") && reloaded == updated,
               "store update should atomically persist a mutation")

        let data = defaults.data(forKey: PetLibraryStateStore.defaultKey)!
        let json = String(decoding: data, as: UTF8.self)
        expect(json.contains("\"displayName\":\"米墨\""),
               "display aliases for every familiar should survive persistence")
        defaults.set(Data("{\"schemaVersion\":99,\"metadataByCharacterID\":{}}".utf8),
                     forKey: PetLibraryStateStore.defaultKey)
        expectThrows("unsupported persisted schemas must fail closed") {
            _ = try store.load()
        }

        print("pet library tests passed")
    }
}
