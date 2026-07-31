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

        print("release surface tests passed")
    }
}
