// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct DIYStylePresetUITests {
    static func main() throws {
        let html = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let common = try String(
            contentsOfFile: "mac/common.sh", encoding: .utf8)

        expect(common.contains("diy_style_preset.swift"),
               "the app target must compile the canonical preset catalog")
        expect(product.contains("state[\"diyStylePresets\"] = DIYStylePreset.runtimeDictionaries"),
               "Settings state should receive the canonical runtime dictionaries")
        expect(html.contains("const DIY_STYLE_PRESETS=[") &&
               html.contains("function installDIYStylePresets(value)") &&
               html.contains("installDIYStylePresets(state.diyStylePresets)"),
               "Settings should bootstrap then install the native preset catalog")

        for id in ["mimo-v2", "compact-cute", "source-faithful",
                   "warm-storybook", "cool-confident"] {
            expect(html.contains("id:'\(id)'"),
                   "Settings bootstrap should retain stable preset ID \(id)")
        }
        expect(!html.contains("STYLE_TUNING_SUGGESTIONS") &&
               !html.contains("appendStyleTuningSuggestion") &&
               html.contains("DIY_STYLE_PRESETS.map(preset=>"),
               "five preset chips should replace the old phrase suggestions")
        expect(html.contains("function selectDIYStylePreset(id)") &&
               html.contains("petLab.stylePresetID=id") &&
               html.contains("updateStyleTuning(this.value)"),
               "preset selection should seed the note while free text remains editable")

        expect(html.contains("stylePresetID:stylePresetIDForBridge()") &&
               html.contains("type:'petGenerateCandidates'") &&
               html.contains("type:'petGenerateEvolution'"),
               "candidate and evolution messages should carry the selected preset ID")
        expect(html.contains("styleTuningNote:styleTuningForBridge()"),
               "the selected preset must continue through the bounded tuning-note field")

        print("DIY style preset UI tests passed")
    }
}
