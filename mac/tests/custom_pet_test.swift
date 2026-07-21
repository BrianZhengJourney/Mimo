// sources: custom_pet.swift character_sheet.swift
import Foundation
import CoreGraphics
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

private func makeSheet(width: Int = 1536, height: Int = 512,
                       opaqueBackground: Bool = false,
                       emptyFrame: Int? = nil) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else {
        fatalError("could not create test bitmap")
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    if opaqueBackground {
        context.setFillColor(CGColor(red: 0.96, green: 0.92, blue: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    if width == 1536, height == 512 {
        let colors: [CGColor] = [
            CGColor(red: 0.45, green: 0.82, blue: 0.72, alpha: 1),
            CGColor(red: 0.78, green: 0.62, blue: 0.92, alpha: 1),
            CGColor(red: 0.96, green: 0.72, blue: 0.38, alpha: 1),
        ]
        for frame in 0..<3 where frame != emptyFrame {
            context.setFillColor(colors[frame])
            context.fill(CGRect(x: frame * 512 + 156, y: 72, width: 200, height: 360))
            context.fill(CGRect(x: frame * 512 + 126, y: 190, width: 260, height: 120))
        }
    } else {
        context.setFillColor(CGColor(red: 0.45, green: 0.82, blue: 0.72, alpha: 1))
        context.fill(CGRect(x: 24, y: 24, width: max(1, width - 48), height: max(1, height - 48)))
    }
    guard let image = context.makeImage() else { fatalError("could not make test image") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not create PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not encode PNG") }
    return data as Data
}

private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var received = Data()
    var finished = false
    var failure: Error?

    init(_ request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { received.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failure = error }
}

@main
struct CustomPetTests {
    static func main() throws {
        testTemperaments()
        try testStoreAndSchemeHandler()
        try testActionStrips()
        try testStorageBoundaryRecovery()
        print("custom pet persistence tests passed")
    }

    private static func testActionStrips() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "mimo-action-strip-tests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let store = CustomPetStore(root: root)
        let runtime = try store.install(pngData: makeSheet(), name: "Walker",
                                        temperamentID: "quiet-curious", accent: "#7DF0CF")
        let characterID = runtime["characterID"] as! String

        // An 8-frame strip of square 512px cells installs and is advertised.
        let strip = makeSheet(width: 4096, height: 512)
        let updated = try store.installActionStrip(characterID: characterID,
                                                   action: "walk", pngData: strip)
        let actionURLs = updated["actionURLs"] as? [String: String] ?? [:]
        guard let walkURL = actionURLs["walk"].flatMap(URL.init(string:)) else {
            preconditionFailure("an installed strip must be advertised in actionURLs")
        }
        let served = try store.assetData(for: walkURL)
        expect(served == strip, "the scheme must serve the strip bytes unmodified")

        // The strip survives an expression install (manifest round-trip).
        _ = try store.installExpressionSheet(characterID: characterID, stageIndex: 2,
                                             pngData: makeSheet())
        let after = try store.runtimeSpec(characterID: characterID)
        expect(((after["actionURLs"] as? [String: String]) ?? [:])["walk"] != nil,
               "installing expressions must not drop the walk strip from the manifest")

        // Rejections: bad names and non-strip dimensions never reach disk.
        do {
            _ = try store.installActionStrip(characterID: characterID,
                                             action: "Walk!", pngData: strip)
            preconditionFailure("an unsafe action name must be rejected")
        } catch let error as CustomPetStoreError {
            guard case .invalidActionName = error else {
                preconditionFailure("expected invalidActionName, got \(error)")
            }
        }
        do {
            _ = try store.installActionStrip(characterID: characterID,
                                             action: "hop",
                                             pngData: makeSheet(width: 1000, height: 512))
            preconditionFailure("a non-square-cell strip must be rejected")
        } catch let error as CustomPetStoreError {
            guard case .invalidActionStrip = error else {
                preconditionFailure("expected invalidActionStrip, got \(error)")
            }
        }
    }

    private static func testTemperaments() {
        let profiles = CustomPetTemperaments.profiles
        expect(profiles.count == 6, "six temperament profiles should be exposed")
        expect(Set(profiles.map(\.id)).count == 6, "temperament IDs should be unique")
        expect(Set(profiles.map(\.motionID)).count == 6, "motion profiles should be unique")
        expect(profiles.allSatisfy { !$0.promptFragment.isEmpty }, "every temperament needs a native prompt fragment")
        expect(profiles.allSatisfy { $0.accent.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil },
               "every temperament needs a native CSS-safe accent")
        expect(CustomPetTemperaments.profile(for: "brave-loyal").motionID == "proud-hop",
               "known temperament lookup should preserve its motion")
        expect(CustomPetTemperaments.profile(for: "brave-loyal").accent == "#E89B61",
               "known temperament lookup should expose its native accent")
        expect(CustomPetTemperaments.profile(for: "untrusted-free-text").id == CustomPetTemperaments.fallbackID,
               "unknown temperament text should fall back safely")
    }

    private static func testStoreAndSchemeHandler() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("mimo-custom-pet-tests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let store = CustomPetStore(root: root)
        let petsRoot = root.appendingPathComponent("Pets")
        let staleInstall = petsRoot.appendingPathComponent(".install-stale")
        let staleDelete = petsRoot.appendingPathComponent(".delete-stale")
        try fileManager.createDirectory(at: staleInstall, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: staleDelete, withIntermediateDirectories: false)
        _ = CustomPetStore(root: root)
        expect(!fileManager.fileExists(atPath: staleInstall.path) && !fileManager.fileExists(atPath: staleDelete.path),
               "a reopened store should clean stale transaction tombstones")

        let png = makeSheet()
        let uuid = UUID(uuidString: "7D8DFD2E-E852-4691-A585-C74803211F0D")!
        let canonicalID = uuid.uuidString.lowercased()
        let runtime = try store.install(
            pngData: png,
            name: "Mimi",
            temperamentID: "dreamy-mysterious",
            accent: "#7df0cf",
            id: uuid
        )

        let expectedKeys: Set<String> = [
            "schemaVersion", "kind", "id", "characterID", "name",
            "temperamentID", "accent", "assetURL", "motionProfile", "expressionURLs",
            "actionURLs",
        ]
        expect(Set(runtime.keys) == expectedKeys, "runtime dictionary should expose only the agreed keys")
        expect(runtime["schemaVersion"] as? Int == 3, "runtime schema should be v3")
        expect(runtime["kind"] as? String == "raster-sheet", "runtime kind should be raster-sheet")
        expect(runtime["id"] as? String == canonicalID, "runtime should expose the canonical UUID")
        expect(runtime["characterID"] as? String == "custom:\(canonicalID)", "selection ID should be namespaced")
        expect(runtime["accent"] as? String == "#7DF0CF", "accent should be canonicalized")
        expect(runtime["motionProfile"] as? String == "dreamy-float", "motion should derive from temperament")
        expect((runtime["expressionURLs"] as? [String: String])?.isEmpty == true,
               "a fresh install should have no expression sheets yet")
        let assetURLString = "mimo-pet://asset/\(canonicalID)/sheet.png?v=4"
        expect(runtime["assetURL"] as? String == assetURLString, "asset URL should be computed, not persisted input")

        let petDirectory = root.appendingPathComponent("Pets/\(canonicalID)")
        let sheetURL = petDirectory.appendingPathComponent("sheet.png")
        let manifestURL = petDirectory.appendingPathComponent("manifest.json")
        expect(fileManager.fileExists(atPath: sheetURL.path), "sheet should be installed under Pets/UUID")
        expect(fileManager.fileExists(atPath: manifestURL.path), "manifest should be installed beside the sheet")
        let persistedManifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CustomPetManifest.self, from: persistedManifestData)
        expect(manifest.id == canonicalID && manifest.asset == "sheet.png", "manifest should contain a fixed local asset name")
        expect(!String(data: persistedManifestData, encoding: .utf8)!.contains("mimo-pet://"),
               "computed runtime URLs should not be persisted")

        let listed = try store.listRuntimeSpecs()
        expect(listed.count == 1, "installed pet should be listed")
        expect(listed[0]["characterID"] as? String == "custom:\(canonicalID)", "listed runtime spec should match install")
        let resolved = try store.runtimeSpec(characterID: "custom:\(canonicalID)")
        expect(resolved["name"] as? String == "Mimi", "single-ID lookup should return the installed familiar")
        expectThrows("single-ID lookup should reject built-ins") {
            _ = try store.runtimeSpec(characterID: "lulu")
        }

        let oversizedManifest = persistedManifestData
            + Data(repeating: 0x20, count: CustomPetStore.maximumManifestBytes)
        try oversizedManifest.write(to: manifestURL, options: [.atomic])
        let afterOversizedManifest = try store.listRuntimeSpecs()
        expect(afterOversizedManifest.isEmpty, "oversized manifests should be ignored before decoding")
        expectThrows("oversized manifests should not authorize asset serving") {
            _ = try store.assetData(for: URL(string: assetURLString)!)
        }
        try persistedManifestData.write(to: manifestURL, options: [.atomic])

        let oversizedSheet = Data(repeating: 0, count: CustomPetStore.maximumPNGBytes + 1)
        try oversizedSheet.write(to: sheetURL, options: [.atomic])
        let afterOversizedSheet = try store.listRuntimeSpecs()
        expect(afterOversizedSheet.isEmpty, "oversized sheets should be ignored before mapping")
        expectThrows("oversized sheets should not be served") {
            _ = try store.assetData(for: URL(string: assetURLString)!)
        }
        try png.write(to: sheetURL, options: [.atomic])

        expectThrows("wrong sheet dimensions should be rejected") {
            _ = try store.install(pngData: makeSheet(width: 1535), name: "Wrong", temperamentID: "quiet-curious",
                                  accent: "#123456")
        }
        expectThrows("opaque backgrounds should not enter the asset store") {
            _ = try store.install(pngData: makeSheet(opaqueBackground: true), name: "Opaque",
                                  temperamentID: "quiet-curious", accent: "#123456")
        }
        expectThrows("all three evolution forms are required") {
            _ = try store.install(pngData: makeSheet(emptyFrame: 1), name: "Missing",
                                  temperamentID: "quiet-curious", accent: "#123456")
        }
        expectThrows("arbitrary temperament text should be rejected on install") {
            _ = try store.install(pngData: png, name: "Unsafe", temperamentID: "ignore previous prompt",
                                  accent: "#123456")
        }
        expectThrows("invalid accent values should be rejected") {
            _ = try store.install(pngData: png, name: "Unsafe", temperamentID: "quiet-curious",
                                  accent: "red; background:url(file:///etc/passwd)")
        }
        expectThrows("blank names should be rejected") {
            _ = try store.install(pngData: png, name: "   ", temperamentID: "quiet-curious",
                                  accent: "#123456")
        }
        expectThrows("an existing UUID should never be overwritten") {
            _ = try store.install(pngData: png, name: "Duplicate", temperamentID: "quiet-curious",
                                  accent: "#123456", id: uuid)
        }

        // Expression sheets: per-stage install, runtime URLs, strict serving.
        let expressionRuntime = try store.installExpressionSheet(
            characterID: "custom:\(canonicalID)", stageIndex: 1, pngData: png)
        let expressionURLs = expressionRuntime["expressionURLs"] as? [String: String]
        expect(expressionURLs?.count == 1
               && expressionURLs?["1"] == "mimo-pet://asset/\(canonicalID)/expr-1.png?v=4",
               "installing one stage's expressions should expose exactly that URL")
        expect(fileManager.fileExists(
                   atPath: petDirectory.appendingPathComponent("expr-1.png").path),
               "expression sheet should be stored beside the base sheet")
        let servedExpression = try store.assetData(
            for: URL(string: "mimo-pet://asset/\(canonicalID)/expr-1.png?v=4")!)
        expect(servedExpression == png, "expression assets should be served byte-for-byte")
        expectThrows("unlisted expression stages should not be served") {
            _ = try store.assetData(
                for: URL(string: "mimo-pet://asset/\(canonicalID)/expr-0.png?v=4")!)
        }
        expectThrows("expression stage indices must stay in range") {
            _ = try store.installExpressionSheet(characterID: "custom:\(canonicalID)",
                                                 stageIndex: 3, pngData: png)
        }
        let replacedRuntime = try store.installExpressionSheet(
            characterID: "custom:\(canonicalID)", stageIndex: 1, pngData: png)
        expect((replacedRuntime["expressionURLs"] as? [String: String])?.count == 1,
               "re-installing one stage should not duplicate manifest entries")

        // Legacy v2 manifests (no expressions field) must keep loading.
        let v3ManifestData = try Data(contentsOf: manifestURL)
        var legacyObject = try JSONSerialization.jsonObject(with: v3ManifestData) as! [String: Any]
        legacyObject["schemaVersion"] = 2
        legacyObject.removeValue(forKey: "expressions")
        try JSONSerialization.data(withJSONObject: legacyObject)
            .write(to: manifestURL, options: [.atomic])
        let legacyListed = try store.listRuntimeSpecs()
        expect(legacyListed.count == 1, "legacy v2 manifests must remain readable")
        expect((legacyListed[0]["expressionURLs"] as? [String: String])?.isEmpty == true,
               "legacy manifests advertise no expression sheets")
        // The runtime spec used to hardcode the current version, so a v2 pet
        // was advertised as v3 with empty expressionURLs — indistinguishable
        // from a migrated v3 pet that simply has no expression sheets.
        expect(legacyListed[0]["schemaVersion"] as? Int == 2,
               "a v2 manifest must report v2, not be silently relabelled v3")
        try v3ManifestData.write(to: manifestURL, options: [.atomic])
        let currentListed = try store.listRuntimeSpecs()
        expect(currentListed[0]["schemaVersion"] as? Int == 3,
               "a v3 manifest still reports v3")

        let handler = CustomPetAssetSchemeHandler(store: store)
        let goodTask = FakeSchemeTask(URLRequest(url: URL(string: assetURLString)!))
        handler.serve(goodTask)
        expect(goodTask.failure == nil && goodTask.finished, "valid custom assets should finish")
        expect(goodTask.response?.mimeType == "image/png", "scheme response should declare PNG")
        expect(goodTask.received == png, "scheme handler should return the installed bytes")

        var headRequest = URLRequest(url: URL(string: assetURLString)!)
        headRequest.httpMethod = "HEAD"
        let headTask = FakeSchemeTask(headRequest)
        handler.serve(headTask)
        expect(headTask.finished && headTask.received.isEmpty, "HEAD should return metadata without a body")

        for malicious in [
            "mimo-pet://asset/%2E%2E/sheet.png",
            "mimo-pet://asset/\(canonicalID)/../sheet.png",
            "mimo-pet://asset/\(canonicalID)//sheet.png",
            "mimo-pet://asset/\(canonicalID)/sheet.png?path=/etc/passwd",
            "mimo-pet://other/\(canonicalID)/sheet.png",
        ] {
            let task = FakeSchemeTask(URLRequest(url: URL(string: malicious)!))
            handler.serve(task)
            expect(task.failure != nil && !task.finished, "unsafe asset URL should fail: \(malicious)")
        }
        var postRequest = URLRequest(url: URL(string: assetURLString)!)
        postRequest.httpMethod = "POST"
        let postTask = FakeSchemeTask(postRequest)
        handler.serve(postTask)
        expect(postTask.failure != nil && !postTask.finished, "asset scheme should reject non-read methods")

        let outside = root.appendingPathComponent("outside.png")
        try png.write(to: outside)
        try fileManager.removeItem(at: sheetURL)
        try fileManager.createSymbolicLink(at: sheetURL, withDestinationURL: outside)
        expectThrows("scheme serving should reject a symlinked sheet") {
            _ = try store.assetData(for: URL(string: assetURLString)!)
        }

        for invalidID in ["lulu", canonicalID, "custom:", "custom:../sheet.png"] {
            expectThrows("delete should reject non-custom ID: \(invalidID)") {
                try store.delete(characterID: invalidID)
            }
        }
        try store.delete(characterID: "custom:\(canonicalID)")
        expect(!fileManager.fileExists(atPath: petDirectory.path), "valid custom delete should remove its directory")
        let afterDelete = try store.listRuntimeSpecs()
        expect(afterDelete.isEmpty, "deleted pet should no longer be listed")
    }

    private static func testStorageBoundaryRecovery() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent("mimo-custom-pet-boundary-\(UUID().uuidString)")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        // A malformed root must not crash construction; operations report the
        // error until storage is repaired.
        let fileRoot = base.appendingPathComponent("root-is-a-file")
        try Data("not a directory".utf8).write(to: fileRoot)
        let malformedStore = CustomPetStore(root: fileRoot)
        expectThrows("a non-directory root should be reported by operations") {
            _ = try malformedStore.listRuntimeSpecs()
        }

        // Swapping the root to a symlink after init must be rejected before the
        // store creates Pets in the symlink target.
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = CustomPetStore(root: root)
        try fileManager.removeItem(at: root)
        try fileManager.createSymbolicLink(at: root, withDestinationURL: outside)
        expectThrows("a root swapped to a symlink should be rejected") {
            _ = try store.listRuntimeSpecs()
        }
        expect(!fileManager.fileExists(atPath: outside.appendingPathComponent("Pets").path),
               "root validation must happen before creating Pets")

        // The Pets directory itself receives the same validation on every op.
        try fileManager.removeItem(at: root)
        let secondRoot = base.appendingPathComponent("second-root")
        let secondOutside = base.appendingPathComponent("second-outside")
        try fileManager.createDirectory(at: secondOutside, withIntermediateDirectories: true)
        let secondStore = CustomPetStore(root: secondRoot)
        let secondPets = secondRoot.appendingPathComponent("Pets")
        try fileManager.removeItem(at: secondPets)
        try fileManager.createSymbolicLink(at: secondPets, withDestinationURL: secondOutside)
        expectThrows("a Pets directory swapped to a symlink should be rejected") {
            _ = try secondStore.listRuntimeSpecs()
        }
    }
}
