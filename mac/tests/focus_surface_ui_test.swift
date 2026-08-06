// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct FocusSurfaceUITests {
    static func main() throws {
        let overlay = try String(
            contentsOfFile: "mac/overlay.html", encoding: .utf8)
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let readme = try String(
            contentsOfFile: "README.md", encoding: .utf8)

        expect(main.contains("\u{5f00}\u{59cb}\u{4e13}\u{6ce8}") &&
               main.contains("Start Focus") &&
               main.contains("#selector(startFocusTimer(_:))") &&
               !main.contains("\u{5f00}\u{59cb}\u{4e00}\u{6b21}\u{5192}\u{9669}") &&
               !main.contains("Begin a quest"),
               "the native menu should expose the timer as Focus, not a quest")

        expect(overlay.contains("const J_VIEWS = [") &&
               overlay.contains("{ id: 'today', zh: '\u{4eca}\u{5929}', en: 'today' }") &&
               overlay.contains("{ id: 'week', zh: '\u{672c}\u{5468}', en: 'week' }") &&
               overlay.contains("J.view === 'week'") &&
               overlay.contains("tx('\u{2726} \u{672c}\u{5468}', '\u{2726} this week')") &&
               !overlay.contains("J_TIMEFRAMES") &&
               !overlay.contains("jSetTf(") &&
               !overlay.contains("renderQuest("),
               "the journal should have only Today and Week, without duplicate ranges or Quest")
        expect(overlay.contains("function famShowJournal(){") &&
               overlay.contains("J.view='today';J.openSess=null;") &&
               main.contains("js(\"famShowJournal()\")") &&
               !main.contains("famShowJournal(true)") &&
               overlay.contains("if (J.view === 'week')  return renderWeek();") &&
               overlay.contains("buildPeriodRail(w0, now, 1440)"),
               "opening the journal should always land on the complete Today view")

        for token in ["id=\"hud\"", "id=\"flame\"", "id=\"streak\"",
                      "flamefill", "renderStreak()", "\u{706b}\u{82d7}\u{6643}\u{4e86}\u{6643}",
                      "\u{8fde}\u{7eed}\u{4e13}\u{6ce8} <b>"] {
            expect(!overlay.contains(token),
                   "the release overlay should not retain visible flame/streak token \(token)")
        }
        expect(!overlay.contains("const s25 = windowStats(25)") &&
               !overlay.contains("const s60 = windowStats(60)") &&
               overlay.contains("const st = rangeStats(w0, now);") &&
               !overlay.contains("windowStats(24 * 60)"),
               "Today should not repeat 25-minute and one-hour range summaries")
        expect(overlay.contains("Fam.focusStartedAt = null;") &&
               !overlay.contains("sound('streak')") &&
               !main.contains("\"streak\": \"Ping\"") &&
               !overlay.contains("function famExportMD()") &&
               !main.contains("func exportJournal()"),
               "neutral activity and dead export code should not retain streak-era behavior")

        expect(overlay.contains("id=\"focusTimerLabel\">\u{4e13}\u{6ce8}</span>") &&
               overlay.contains("tx('\u{7ed3}\u{675f}\u{4e13}\u{6ce8}', 'End Focus')") &&
               overlay.contains("\u{4e13}\u{6ce8}\u{5f00}\u{59cb}\u{2014}\u{2014}${min} \u{5206}\u{949f}") &&
               overlay.contains("Focus started \u{2014} ${min} minutes") &&
               !overlay.contains("the quest begins") &&
               !overlay.contains("quest called off"),
               "the real timer should use plain Focus language")

        expect(settings.contains("\u{58f0}\u{97f3}\u{ff08}\u{4e13}\u{6ce8}\u{5b8c}\u{6210}\u{3001}\u{5206}\u{5fc3}\u{63d0}\u{9192}\u{ff09}") &&
               settings.contains("\u{5f00}\u{59cb}\u{4e13}\u{6ce8}\u{2014}\u{2014}\u{9009}\u{62e9} 25 \u{6216} 50 \u{5206}\u{949f}") &&
               !settings.contains("begin a quest") &&
               !settings.contains("focus streaks"),
               "Settings should teach Focus without retired game language")
        expect(settings.contains("rule-groups")
               && settings.contains("rule-segment")
               && settings.contains("technicalRules")
               && settings.contains("本机与技术地址")
               && settings.contains("ruleSource"),
               "focus categories should use a visual three-way control and fold technical hosts away")
        expect(main.contains("isTechnicalActivityKey")
               && main.contains("198.18") && main.contains("192.168"),
               "loopback, private-network, and benchmark addresses should be recognized as technical noise")
        expect(!readme.contains("focus quests") &&
               !readme.contains("strip, quest log"),
               "release documentation should match the Today/Week surface")

        expect(overlay.contains("event.target.closest('#journal')"),
               "clicking outside the Today journal must still dismiss it")
        print("focus surface UI tests passed")
    }
}
