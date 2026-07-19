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

        try store.purgeExpired(now: now.addingTimeInterval(FamiliarGenerationDraftStore.retention + 1))
        expectThrows("expired drafts should be removed") { _ = try store.manifest(requestID: requestID) }
        print("generation draft tests passed")
    }
}
