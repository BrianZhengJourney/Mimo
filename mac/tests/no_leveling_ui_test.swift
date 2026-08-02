// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct NoLevelingUITests {
    static func main() throws {
        let overlay = try String(
            contentsOfFile: "mac/overlay.html", encoding: .utf8)
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)
        let runtime = try String(
            contentsOfFile: "mac/companion_runtime.swift", encoding: .utf8)
        let director = try String(
            contentsOfFile: "mac/companion_director.swift", encoding: .utf8)
        let expression = try String(
            contentsOfFile: "mac/companion_expression.swift", encoding: .utf8)
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)

        let forbiddenOverlay = [
            "lvlChip", "xpbar", "xpStorageKeyFor", "xpToNext", "addXP",
            "levelUp:", "famPreviewEvolution", "Fam.level", "Fam.xp",
            "resRow", "renderRes", "RESOURCE_FOR", "Fam.gain",
            "resources:", "protein:", "spellbook:", "fragment:",
            "rowsForLevel", "artForLevel", "stageForLevel",
            "renderQuest(", "J_TIMEFRAMES", "id=\"flame\"", "id=\"streak\"",
        ]
        for token in forbiddenOverlay {
            expect(!overlay.contains(token),
                   "overlay should not retain leveling token \(token)")
        }
        expect(!main.contains("case \"levelUp\"") &&
               !main.contains("victoryWalk") &&
               !main.contains("previewEvolution") &&
               !main.contains("\"gain\": \"Tink\"") &&
               !main.contains("spellbooks"),
               "Swift should not retain level-up events or milestone walks")
        expect(!runtime.contains("var level: Double") &&
               !director.contains("mimo.level") &&
               !expression.contains("\"mimo.level\""),
               "behavior runtime should expose focus semantics without a level")
        expect(!settings.contains("升级") &&
               !settings.contains("成长") &&
               !settings.contains("蛋白质") &&
               !settings.contains("魔法书") &&
               settings.contains("专注分类") &&
               settings.contains("生成完整伴灵") &&
               settings.contains("Medium / High 定稿"),
               "Settings should describe final generation and focus sounds without upgrades")
        expect(!product.contains("成长等级") &&
               !product.contains("成长图") &&
               !product.contains("XP、等级"),
               "privacy and deletion copy should not promise obsolete level data")
        expect(!overlay.contains("正在成长") &&
               !overlay.contains("renderRes") &&
               overlay.contains("正在专注"),
               "the release overlay should expose focus without resource pickups")
        expect(overlay.contains("const MATURE_STAGE = 2") &&
               overlay.contains("✓ 专注完成") &&
               overlay.contains("🎉 做出来了！"),
               "mature art, focus completion, and cute celebration should remain")

        print("no leveling UI tests passed")
    }
}
