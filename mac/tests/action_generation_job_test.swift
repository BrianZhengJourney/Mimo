// sources: action_generation_job.swift custom_pet.swift character_sheet.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

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
    } catch {
        // Expected.
    }
}

private func makePNG(width: Int, height: Int = 512) -> Data {
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.4, green: 0.7, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 16, y: 16, width: width - 32, height: height - 32))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

private func writeBundle(at url: URL, metadata: ActionResultBundleMetadata,
                         hardPass: Bool, includePreview: Bool = true) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let prefix = "action-\(metadata.action)"
    try makePNG(width: metadata.frameCount * metadata.cellSize).write(
        to: url.appendingPathComponent(metadata.stripFilename))
    try encoder.encode(metadata).write(
        to: url.appendingPathComponent("\(prefix).metadata.json"))
    let qa: [String: Any] = [
        "schemaVersion": 1,
        "hardPass": hardPass,
        "automaticInstallAllowed": false,
        "manualReviewRequired": true,
        "cycleDistanceAuthored": ["pass": metadata.cycleDistanceCellPixels != nil],
    ]
    try JSONSerialization.data(withJSONObject: qa, options: [.prettyPrinted, .sortedKeys])
        .write(to: url.appendingPathComponent(metadata.qaFilename))
    if includePreview {
        try makePNG(width: 1024, height: 512).write(
            to: url.appendingPathComponent("\(prefix)-contact-sheet.png"))
    }
}

@main
struct ActionGenerationJobTests {
    static let characterID = "custom:7d8dfd2e-e852-4691-a585-c74803211f0d"

    static func metadata(cycle: Double? = 144) -> ActionResultBundleMetadata {
        ActionResultBundleMetadata(
            schemaVersion: 1,
            action: "walk",
            stripFilename: "action-walk.png",
            frameCount: 24,
            cellSize: 512,
            framesPerSecond: 30,
            cycleDistanceCellPixels: cycle,
            anchorInCell: [256, 502],
            qaFilename: "action-walk.qa.json",
            automaticInstallAllowed: false)
    }

    static func testImportPersistsAndServesCanonicalAssets() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "mimo-action-job-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("external-wan-result")
        try writeBundle(at: source, metadata: metadata(), hardPass: true)

        let storeRoot = root.appendingPathComponent("app-owned")
        let store = ActionGenerationJobStore(root: storeRoot)
        let id = UUID(uuidString: "B89103AE-3AD8-4FEE-B097-E72A980774CA")!
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let job = try store.importResultBundle(at: source, characterID: characterID,
                                               now: created, id: id)
        expect(job.id == id.uuidString.lowercased(), "job IDs should be canonical")
        expect(job.checkerPassed == true && job.isEligibleForManualInstall,
               "hard QA plus authored gait distance should permit manual acceptance")
        expect(job.stripAsset == "strip.png" && job.previewAsset == "preview.png"
               && job.checkerAsset == "checker.json",
               "external filenames should be copied into a canonical app-owned layout")

        let runtime = store.runtimeDictionary(for: job)
        expect(runtime["cycleDistanceCellPixels"] as? Double == 144,
               "runtime state should keep source-cell distance units explicit")
        expect(runtime["cycleDistanceUnits"] as? String == "cell-pixels",
               "runtime state should label the units")
        expect(runtime["installEligible"] as? Bool == true,
               "Settings should receive the fail-closed install gate")
        let stripURL = URL(string: runtime["stripURL"] as! String)!
        expect(stripURL.scheme == ActionGenerationJobStore.scheme,
               "Settings assets should use the bounded job scheme, not file URLs")
        expect(!stripURL.absoluteString.contains(source.path),
               "runtime state must never expose the selected external path")
        let served = try store.asset(for: stripURL)
        let persistedStrip = try store.stripData(jobID: job.id)
        expect(served.mimeType == "image/png" && served.data == persistedStrip,
               "the scheme resolver should serve the persisted canonical strip")

        // Reconstructing the store simulates Settings close and app restart.
        let reopened = ActionGenerationJobStore(root: storeRoot)
        let persisted = reopened.jobs(characterID: characterID)
        expect(persisted.count == 1 && persisted[0] == job,
               "an imported review job must survive store reconstruction")
        let installed = try reopened.markInstalled(jobID: job.id,
                                                   now: created.addingTimeInterval(10))
        expect(installed.installedAt != nil, "manual acceptance state should persist")
        expect(ActionGenerationJobStore(root: storeRoot).jobs()[0].installedAt != nil,
               "installed state should survive app restart too")
    }

    static func testFailClosedQAAndBundleBoundary() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "mimo-action-job-boundary-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ActionGenerationJobStore(root: root.appendingPathComponent("store"))

        let failed = root.appendingPathComponent("failed-qa")
        try writeBundle(at: failed, metadata: metadata(cycle: nil), hardPass: false,
                        includePreview: false)
        let imported = try store.importResultBundle(at: failed, characterID: characterID)
        expect(imported.checkerPassed == false && !imported.isEligibleForManualInstall,
               "failed QA may be previewed but must never be install-eligible")
        expect(store.runtimeDictionary(for: imported)["previewURL"] == nil,
               "contact sheet is optional")

        let unknown = root.appendingPathComponent("unknown-file")
        try writeBundle(at: unknown, metadata: metadata(), hardPass: true)
        try Data("surprise".utf8).write(to: unknown.appendingPathComponent("driver.mp4"))
        expectThrows("files outside the bundle contract must be rejected") {
            _ = try store.importResultBundle(at: unknown, characterID: characterID)
        }

        let symlinked = root.appendingPathComponent("symlink-strip")
        try writeBundle(at: symlinked, metadata: metadata(), hardPass: true)
        let strip = symlinked.appendingPathComponent("action-walk.png")
        try fm.removeItem(at: strip)
        let outside = root.appendingPathComponent("outside.png")
        try makePNG(width: 24 * 512).write(to: outside)
        try fm.createSymbolicLink(at: strip, withDestinationURL: outside)
        expectThrows("a symlinked action strip must never be followed") {
            _ = try store.importResultBundle(at: symlinked, characterID: characterID)
        }

        // Codable structs are immutable; mutate the encoded JSON to preserve a
        // realistic producer error while keeping the exact external filenames.
        let mismatch = root.appendingPathComponent("frame-mismatch")
        try writeBundle(at: mismatch, metadata: metadata(), hardPass: true)
        let metadataURL = mismatch.appendingPathComponent("action-walk.metadata.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
            as! [String: Any]
        object["frameCount"] = 32
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL)
        expectThrows("metadata frame count must match the actual strip width") {
            _ = try store.importResultBundle(at: mismatch, characterID: characterID)
        }
    }

    static func testLiveBundleWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MIMO_ACTION_RESULT_BUNDLE"],
              !path.isEmpty else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "mimo-action-job-live-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ActionGenerationJobStore(root: root.appendingPathComponent("store"))
        let job = try store.importResultBundle(
            at: URL(fileURLWithPath: path, isDirectory: true),
            characterID: characterID)
        expect(job.metadata.frameCount == 24 && job.metadata.cellSize == 512,
               "live Wan bundle must import as one 24 x 512 action strip")
        expect(job.stripAsset == "strip.png" && job.checkerAsset == "checker.json",
               "live Wan assets must be copied into canonical app-owned names")
        expect(job.previewAsset == "preview.png",
               "live Wan acceptance output should include its contact sheet")
        let persistedStrip = try store.stripData(jobID: job.id)
        expect(persistedStrip.count > 0,
               "live Wan strip should be readable after persistence")
        print("live Wan bundle imported; hardPass=\(job.checkerPassed == true), "
              + "installEligible=\(job.isEligibleForManualInstall)")
    }

    static func main() throws {
        try testImportPersistsAndServesCanonicalAssets()
        try testFailClosedQAAndBundleBoundary()
        try testLiveBundleWhenRequested()
        print("action generation job store tests passed")
    }
}
