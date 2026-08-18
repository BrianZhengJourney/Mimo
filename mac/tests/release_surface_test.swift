// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ReleaseSurfaceTests {
    static func main() throws {
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)
        let build = try String(
            contentsOfFile: "mac/build.sh", encoding: .utf8)
        let common = try String(
            contentsOfFile: "mac/common.sh", encoding: .utf8)
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let petGeneration = try String(
            contentsOfFile: "mac/pet_generation.swift", encoding: .utf8)
        let signing = try String(
            contentsOfFile: "mac/setup-local-signing.sh", encoding: .utf8)

        expect(!main.contains("makeCompanionPreviewRoot") &&
               !main.contains("验收动作") &&
               !main.contains("CompanionPreviewCatalog"),
               "release menus should not expose the retired experiment browser")
        expect(!build.contains("assets/preview") &&
               !common.contains("companion_preview_catalog.swift"),
               "the app bundle should not compile or copy retired preview assets")
        expect(!FileManager.default.fileExists(
            atPath: "mac/assets/preview"),
               "retired preview fixtures should not remain in the release tree")
        expect(!product.lowercased().contains("pixellab") &&
               !petGeneration.lowercased().contains("pixellab"),
               "release credential state should expose only the active OpenAI provider")
        expect(build.contains("MimoBuildCommit")
               && build.contains("MimoBuildSignature")
               && build.contains("Mimo Local Development")
               && signing.contains("-p codeSign")
               && signing.contains("-T /usr/bin/codesign")
               && signing.contains(" -x ")
               && !signing.contains(" -A "),
               "local builds expose their identity and the optional stable key stays non-exportable and codesign-scoped")
        expect(signing.contains("/usr/bin/openssl req")
               && signing.contains("/usr/bin/openssl pkcs12")
               && signing.contains("/usr/bin/openssl rand -hex 32")
               && signing.contains("-passout \"pass:$MIMO_SIGNING_PASSWORD\"")
               && signing.contains("-P \"$MIMO_SIGNING_PASSWORD\"")
               && !signing.contains("-passout pass:"),
               "stable signing uses the system OpenSSL and a non-empty ephemeral PKCS#12 password")

        print("release surface tests passed")
    }
}
