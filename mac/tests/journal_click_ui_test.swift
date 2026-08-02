// sources: starter_action.swift companion_geometry.swift companion_physics.swift companion_sprite.swift companion_expression.swift companion_behavior.swift companion_director.swift companion_window.swift companion_runtime.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct JournalClickUITests {
    static func main() throws {
        let overlay = try String(
            contentsOfFile: "mac/overlay.html", encoding: .utf8)
        let main = try String(
            contentsOfFile: "mac/main.swift", encoding: .utf8)
        let runtime = try String(
            contentsOfFile: "mac/companion_runtime.swift", encoding: .utf8)
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)

        expect(overlay.contains("function famShowJournal(){") &&
               overlay.contains("J.view='today';J.openSess=null;"),
               "a pet tap should open the complete journal directly on today")
        expect(!overlay.contains("function famShowFocusBrief") &&
               !overlay.contains("🐾 今天专注得怎么样？"),
               "the intermediate focus summary card should be removed")
        expect(overlay.contains("body.native-hosted .familiar") &&
               !overlay.contains("body.native-hosted .stage{ display:none; }"),
               "native pets must hide only duplicate art, not the journal")
        expect(overlay.contains("event.target.closest('#journal')") &&
               overlay.contains("suppressFamiliarOpenOnce=!!event.target.closest('#familiar')") &&
               overlay.contains("const suppressOpen=suppressFamiliarOpenOnce;") &&
               overlay.contains("else if (suppressOpen)") &&
               main.contains("addGlobalMonitorForEvents") &&
               main.contains("event.window !== self.panel"),
               "clicks outside the journal should dismiss it inside and outside the app")
        expect(main.contains("func showJournal(near screenPoint: CGPoint? = nil)") &&
               main.contains("companionRuntime.onPress =") &&
               main.contains("nativePressDismissedJournal = self.bubbleOpen") &&
               main.contains("if self.nativePressDismissedJournal") &&
               main.contains("showJournal(near: point)") &&
               main.contains("case \"famClick\":\n            showJournal()"),
               "both native and web-hosted pets should open the same full journal")
        expect(runtime.contains("onPress?(point)") &&
               runtime.contains("onClick?(pressAnchor)"),
               "native press and click phases must preserve dismissal and cute reactions")
        expect(settings.contains("直接打开完整手记的今天视图"),
               "Settings should teach the direct journal interaction")
        print("journal click UI tests passed")
    }
}
