// sources: generation_draft.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func expectThrows(_ message: String, _ body: () throws -> Void) {
    do { try body(); expect(false, message) } catch { }
}

private final class FailingRemoveFileManager: FileManager {
    var blockedPath: String?

    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL.path == blockedPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

@main
struct GenerationDraftTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mimo-generation-drafts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = FamiliarGenerationDraftStore(root: root)
        let requestID = UUID().uuidString
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let now = Date()

        let received = try store.saveRaw(requestID: requestID, pngData: png, phase: .evolution,
                                         quality: "medium", providerSeconds: 41.25, now: now)
        expect(received.status == .received && received.providerSeconds == 41.25,
               "raw provider artifact and timing should be recorded")
        let firstRaw = try store.rawData(requestID: requestID)
        expect(firstRaw == png, "raw paid output should be recoverable")

        let failed = try store.markLocalFailure(requestID: requestID,
                                                message: "Bloom touched a panel boundary", localSeconds: 0.72)
        expect(failed.status == .failedLocalProcessing && failed.failureMessage?.contains("Bloom") == true,
               "local failure must remain distinct from provider failure")
        let retainedRaw = try store.rawData(requestID: requestID)
        expect(retainedRaw == png,
               "marking a local failure must not discard the paid output")

        let processed = try store.markProcessed(requestID: requestID, pngData: png,
                                                localSeconds: 0.84, warnings: ["recovered panel overlap"])
        expect(processed.status == .processed && processed.processedAsset == "processed.png",
               "a recovered draft should become processed")
        expect(processed.warnings == ["recovered panel overlap"], "recovery warnings should be transparent")

        expectThrows("arbitrary IDs must not become paths") {
            _ = try store.saveRaw(requestID: "../escape", pngData: png, phase: .candidates,
                                  quality: "low", providerSeconds: nil, now: now)
        }
        expectThrows("non-PNG payloads must be rejected") {
            _ = try store.saveRaw(requestID: UUID().uuidString, pngData: Data("nope".utf8),
                                  phase: .candidates, quality: "low", providerSeconds: nil, now: now)
        }

        let corruptID = UUID().uuidString.lowercased()
        let corruptDirectory = store.folderURL.appendingPathComponent(corruptID, isDirectory: true)
        try fm.createDirectory(at: corruptDirectory, withIntermediateDirectories: false)
        let unrelated = store.folderURL.appendingPathComponent("keep-me.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        try store.purgeAll()
        expectThrows("strict purge should remove valid draft directories") {
            _ = try store.manifest(requestID: requestID)
        }
        expect(!fm.fileExists(atPath: corruptDirectory.path),
               "strict purge should remove safe UUID directories even with corrupt metadata")
        expect(fm.fileExists(atPath: unrelated.path),
               "strict purge must leave unrecognized entries untouched")

        let expiringID = UUID().uuidString
        _ = try store.saveRaw(requestID: expiringID, pngData: png, phase: .candidates,
                              quality: "low", providerSeconds: nil, now: now)
        try store.purgeExpired(now: now.addingTimeInterval(FamiliarGenerationDraftStore.retention + 1))
        expectThrows("expired drafts should be removed") { _ = try store.manifest(requestID: expiringID) }

        let failingRoot = fm.temporaryDirectory
            .appendingPathComponent("mimo-generation-drafts-failure-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: failingRoot) }
        let failingFileManager = FailingRemoveFileManager()
        let failingStore = FamiliarGenerationDraftStore(
            root: failingRoot, fileManager: failingFileManager)
        let blockedID = UUID().uuidString
        _ = try failingStore.saveRaw(
            requestID: blockedID, pngData: png, phase: .evolution,
            quality: "medium", providerSeconds: 1, now: now)
        let blockedDirectory = failingStore.folderURL
            .appendingPathComponent(blockedID.lowercased(), isDirectory: true)
        failingFileManager.blockedPath = blockedDirectory.standardizedFileURL.path
        expectThrows("strict purge must surface any UUID draft deletion failure") {
            try failingStore.purgeAll()
        }
        expect(fm.fileExists(atPath: blockedDirectory.path),
               "a failed strict deletion must never be reported as purged")
        failingFileManager.blockedPath = nil
        try failingStore.purgeAll()
        expect(!fm.fileExists(atPath: blockedDirectory.path),
               "strict purge should succeed once deletion is available")

        let unsafeRoot = fm.temporaryDirectory
            .appendingPathComponent("mimo-generation-drafts-unsafe-\(UUID().uuidString)")
        let external = fm.temporaryDirectory
            .appendingPathComponent("mimo-generation-drafts-external-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: unsafeRoot)
            try? fm.removeItem(at: external)
        }
        let unsafeStore = FamiliarGenerationDraftStore(root: unsafeRoot)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedID = UUID().uuidString.lowercased()
        let link = unsafeStore.folderURL.appendingPathComponent(linkedID)
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        expectThrows("strict purge must reject a UUID symlink instead of following it") {
            try unsafeStore.purgeAll()
        }
        expect(fm.fileExists(atPath: external.path),
               "unsafe UUID entries must not delete data outside the draft root")
        print("generation draft tests passed")
    }
}
