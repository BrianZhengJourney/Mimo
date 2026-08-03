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
        expect(state.recoverableDeletedCharacterIDs(
            validIDs: valid,
            now: base.addingTimeInterval(40 + 6 * 86_400)).isEmpty,
               "hiding and deleting should remain separate states")
        try state.moveToTrash("custom:beta", at: base.addingTimeInterval(40))
        expect(state.recoverableDeletedCharacterIDs(
            validIDs: valid,
            now: base.addingTimeInterval(40 + 6 * 86_400)) == ["custom:beta"],
               "deleted familiars should remain recoverable for seven days")
        expect(state.expiredDeletedCharacterIDs(
            validIDs: valid,
            now: base.addingTimeInterval(40 + 7 * 86_400)) == ["custom:beta"],
               "the seven-day boundary should make deletion irreversible")
        expect(state.deletionDeadline(for: "custom:beta")
            == base.addingTimeInterval(40 + 7 * 86_400),
               "each deleted familiar should expose its exact purge deadline")
        expect(state.metadata(for: "custom:beta")?.category == "Friends",
               "deleting should preserve category metadata")
        try state.restoreFromTrash(
            "custom:beta", now: base.addingTimeInterval(40 + 6 * 86_400))
        expect(state.isArchived("custom:beta"),
               "restoring a previously hidden familiar should return it to Hidden")
        try state.unarchive("custom:beta")
        expect(!state.isArchived("custom:beta"), "unarchive should restore visibility")
        expect(state.metadata(for: "custom:beta")?.lastUsedAt
            == base.addingTimeInterval(20),
               "unarchive should preserve recency metadata")

        let manualOrder = [
            "custom:gamma", "nat", "lulu", "custom:beta", "custom:alpha",
        ]
        try state.setActiveOrder(manualOrder, validIDs: valid)
        expect(state.libraryCharacterIDs(validIDs: valid, expanded: true) == manualOrder,
               "an explicit drag order should become the canonical library order")
        try state.markUsed("lulu", at: base.addingTimeInterval(500))
        expect(state.libraryCharacterIDs(validIDs: valid, expanded: true) == manualOrder,
               "using or selecting a familiar must not change an explicit drag order")
        expect(state.recentCharacterIDs(validIDs: valid)
            == Array(manualOrder.prefix(PetLibraryState.recentLimit)),
               "the collapsed three should follow manual order rather than click recency")
        expectThrows("a reorder cannot omit active familiars") {
            try state.setActiveOrder(Array(manualOrder.dropLast()), validIDs: valid)
        }
        expectThrows("a reorder cannot duplicate familiars") {
            try state.setActiveOrder(
                ["custom:gamma", "nat", "lulu", "custom:beta", "custom:beta"],
                validIDs: valid)
        }
        try state.archive("custom:beta", at: base.addingTimeInterval(600))
        try state.setActiveOrder(
            ["custom:alpha", "custom:gamma", "nat", "lulu"], validIDs: valid)
        try state.unarchive("custom:beta")
        expect(state.libraryCharacterIDs(validIDs: valid, expanded: true)
            == ["custom:alpha", "custom:gamma", "nat", "custom:beta", "lulu"],
               "hidden familiars should retain their order slot across other drags")

        var lifecycle = state
        try lifecycle.moveToTrash("nat", at: base.addingTimeInterval(700))
        expectThrows("restore should close exactly at the seven-day boundary") {
            try lifecycle.restoreFromTrash(
                "nat", now: base.addingTimeInterval(700 + 7 * 86_400))
        }
        expect(lifecycle.expiredDeletedCharacterIDs(
            now: base.addingTimeInterval(700 + 7 * 86_400)) == ["nat"],
               "expiry cleanup should be driven by tombstones even when assets do not enumerate")
        try lifecycle.markBundledPurged(
            "nat", at: base.addingTimeInterval(700 + 7 * 86_400))
        expect(!lifecycle.isSelectable("nat") &&
               !lifecycle.recoverableDeletedCharacterIDs(
                validIDs: valid, now: base.addingTimeInterval(700 + 8 * 86_400)).contains("nat"),
               "expired bundled pets should retain only a non-recoverable tombstone")

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

        let canonicalDeleteID = "custom:7d8dfd2e-e852-4691-a585-c74803211f0d"
        let builtinTarget = try PetLibraryDeletionPolicy.target(for: "lulu")
        let legacyTarget = try PetLibraryDeletionPolicy.target(for: "prototype")
        let customTarget = try PetLibraryDeletionPolicy.target(for: canonicalDeleteID)
        expect(builtinTarget == .builtin("lulu"),
               "bundled delete targets should use reversible library removal")
        expect(legacyTarget == .legacyPrototype,
               "the legacy generated familiar should remain a recognized delete target")
        expect(customTarget == .custom(canonicalDeleteID),
               "canonical custom UUIDs should cross the deletion boundary")
        for unsafe in [
            "custom:../../Pets", "custom:",
            "custom:7D8DFD2E-E852-4691-A585-C74803211F0D", "unknown",
        ] {
            expectThrows("deletion policy must reject noncanonical ID: \(unsafe)") {
                _ = try PetLibraryDeletionPolicy.target(for: unsafe)
            }
        }
        expect(PetLibraryDeletionPolicy.safeBuiltinFallback(excluding: "lulu")
               == "clawd",
               "removing the selected built-in should choose a different safe bundle")

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
        defaults.set(Data("{\"schemaVersion\":1,\"metadataByCharacterID\":{}}".utf8),
                     forKey: PetLibraryStateStore.defaultKey)
        var legacy = try store.load()
        try legacy.reconcileOrder(validIDs: ["lulu", "clawd", "nat"])
        try store.save(legacy)
        let migratedLegacy = try store.load()
        expect(migratedLegacy == legacy,
               "schema-v1 payloads without an explicit order should migrate in place")
        defaults.set(Data("{\"schemaVersion\":99,\"metadataByCharacterID\":{}}".utf8),
                     forKey: PetLibraryStateStore.defaultKey)
        expectThrows("unsupported persisted schemas must fail closed") {
            _ = try store.load()
        }

        print("pet library tests passed")
    }
}
