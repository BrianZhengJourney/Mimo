// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct StarterActionUITests {
    static func main() throws {
        let html = try String(contentsOfFile: "mac/settings.html", encoding: .utf8)
        let bridge = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)

        expect(html.contains("Starter Actions · DIY 动作"),
               "Settings exposes the product action section")
        expect(!html.contains("data-zh=\"Wan 动作验收\""),
               "the external experiment is no longer the product heading")

        for action in StarterActionID.allCases {
            expect(html.contains("\(action.rawValue):{glyph:"),
                   "Settings has a durable card for \(action.rawValue)")
        }
        for event in [
            "petStarterActionStartDefaults", "petStarterActionCancelDefaults",
            "starterActionJobUpdated", "starterActionJobProgress",
            "starterActionJobError",
        ] {
            expect(html.contains(event), "Settings includes \(event)")
            expect(bridge.contains(event), "the native bridge includes \(event)")
        }
        expect(html.contains("Advanced: import an external action result"),
               "local external import remains available as an advanced seam")
        expect(html.contains("一键生成默认动作") &&
               html.contains("${calls} calls · ~$${(calls*each).toFixed(3)}"),
               "one default-pack action discloses total calls and estimated cost")
        expect(!html.contains("onclick=\"startStarterAction('${job.jobID}')"),
               "users do not select or start default actions one by one")
        expect(html.contains("STYLE_TUNING_MIMO_V2") &&
               html.contains("细腻高分辨率像素画") &&
               html.contains("白衣伴灵画风（默认）"),
               "Studio exposes the approved white-outfit Mimo v2 finish as its default tuning note")
        expect(!html.contains("女性角色默认") && !html.contains("applyFemaleStylePreset"),
               "the retired female-personality preset cannot override the Mimo v2 style default")
        expect(html.contains("自动找出人物") &&
               html.contains("生成后手动选择") &&
               html.contains("等待你确认后再生成"),
               "Studio should auto-detect the subject but stop for manual approval after Low drafts")
        for retiredAutoStart in [
            "petArmCandidateAutoStart", "petCandidateAutoStart",
            "armCandidateAutoStart", "candidateAutoStartAt",
            "petLab.candidateIndices=[0]", "8 秒内可换人",
        ] {
            expect(!html.contains(retiredAutoStart),
                   "Settings must not retain the retired Low-to-Medium auto-start: \(retiredAutoStart)")
            expect(!bridge.contains(retiredAutoStart),
                   "native bridge must not retain the retired Low-to-Medium auto-start: \(retiredAutoStart)")
        }
        print("starter action UI contract tests passed")
    }
}
