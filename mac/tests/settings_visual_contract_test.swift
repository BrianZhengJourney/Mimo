// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct SettingsVisualContractTests {
    static func main() throws {
        let html = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let common = try String(
            contentsOfFile: "mac/common.sh", encoding: .utf8)

        for token in ["--paper:#f6f1e8", "--surface:#fffaf3",
                      "--surface-muted:#eee3d5", "--ink:#352c25",
                      "--accent:#91664f"] {
            expect(html.contains(token),
                   "warm minimalist Settings should define \(token)")
        }
        expect(html.contains("background:var(--paper)") &&
               !html.contains("background:linear-gradient(165deg,#1d1838"),
               "the release Settings canvas should be warm paper, not midnight purple")
        expect(html.contains("<h1>🐾 Mimo <span") &&
               html.contains("米墨</span>") &&
               !html.contains("class=\"tagline\"") &&
               !html.contains(".tagline{"),
               "keep the Mimo 米墨 title but remove only its subtitle line")

        expect(html.contains("'PingFang SC','PingFang TC','Hiragino Sans GB'") &&
               html.contains(":root[data-font-family=\"pingfang\"]") &&
               html.contains(":root[data-font-family=\"system\"]") &&
               html.contains(":root[data-font-family=\"rounded\"]") &&
               html.contains("font-family:var(--ui-font-family)"),
               "Settings should have an explicit PingFang-first sans-serif stack")
        expect(!html.contains("Georgia,serif") &&
               !html.contains("Georgia,'Songti SC',serif"),
               "serif islands should not bypass the selected sans-serif family")

        for token in ["id=\"settingsFontFamily\"", "value=\"pingfang\"",
                      "value=\"system\"", "value=\"rounded\"",
                      "id=\"settingsFontWeight\"", "value=\"regular\"",
                      "value=\"medium\"", "value=\"semibold\""] {
            expect(html.contains(token), "missing typography control \(token)")
        }
        expect(html.contains("function applySettingsTypography(family,weight)") &&
               html.contains("document.documentElement.dataset.fontFamily") &&
               html.contains("document.documentElement.dataset.fontWeight") &&
               html.contains("type:'settingsTypography',family,weight"),
               "font controls should apply locally and use one bounded bridge message")

        expect(common.contains("settings_typography.swift") &&
               product.contains("\"settingsFontFamily\"") &&
               product.contains("\"settingsFontWeight\"") &&
               product.contains("case \"settingsTypography\"") &&
               product.contains("MimoSettingsTypography("),
               "Swift should resolve, persist, and push canonical typography state")

        print("settings visual contract tests passed")
    }
}
