// sources: starter_action.swift companion_geometry.swift companion_physics.swift companion_sprite.swift companion_expression.swift companion_behavior.swift companion_director.swift companion_window.swift companion_runtime.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct FocusBriefUITests {
    static func main() throws {
        let overlay = try String(
            contentsOfFile: "mac/overlay.html", encoding: .utf8)
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)
        let runtime = try String(
            contentsOfFile: "mac/companion_runtime.swift", encoding: .utf8)
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)

        expect(overlay.contains("function todayFocusSnapshot()") &&
               overlay.contains("dayStart.setHours(0,0,0,0)") &&
               overlay.contains("🐾 今天专注得怎么样？"),
               "a tap should summarize the calendar day's focus")
        for metric in ["专注占比", "专注", "分心", "连续专注"] {
            expect(overlay.contains(metric),
                   "the focus brief should expose \(metric)")
        }
        expect(overlay.contains("closeBubble();famPomodoro(25)") &&
               overlay.contains("完整手记 ↗"),
               "the brief should lead to a 25-minute focus block or full journal")
        expect(overlay.contains("body.native-hosted .familiar") &&
               !overlay.contains("body.native-hosted .stage{ display:none; }"),
               "native pets must hide only duplicate art, not the focus UI")
        expect(main.contains("func showFocusBrief(near screenPoint: CGPoint? = nil)") &&
               main.contains("showFocusBrief(near: point)") &&
               main.contains("case \"famClick\":\n            showFocusBrief()"),
               "both native and web-hosted pets should open the same brief")
        expect(runtime.contains("onClick?(pressAnchor)"),
               "a successful cute reaction must still deliver the product click")
        expect(settings.contains("马上告诉你今天专注得怎么样"),
               "Settings should teach the one-tap interaction")
        print("focus brief UI tests passed")
    }
}
