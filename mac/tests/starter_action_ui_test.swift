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
            "petStarterActionStart", "petStarterActionCancel",
            "starterActionJobUpdated", "starterActionJobProgress",
            "starterActionJobError",
        ] {
            expect(html.contains(event), "Settings includes \(event)")
            expect(bridge.contains(event), "the native bridge includes \(event)")
        }
        expect(html.contains("Advanced: import an external action result"),
               "local external import remains available as an advanced seam")
        expect(html.contains("calls · ${starterActionCost(job)}"),
               "every start or retry discloses remaining calls and estimated cost")
        print("starter action UI contract tests passed")
    }
}
