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
        let html = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let bridge = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)

        for removedSurface in [
            "id=\"actionImportSection\"", "id=\"actionReview\"",
            "Starter Actions · DIY 动作",
            "Advanced: import an external action result",
        ] {
            expect(!html.contains(removedSurface),
                   "Settings should hide action-generation surface: \(removedSurface)")
        }
        for removedControl in [
            "renderActionReview", "starterActionCards", "startStarterAction",
            "startDefaultStarterActions", "requestActionBundle",
            "previewActionJob", "acceptActionJob",
            "petStarterActionStartDefaults",
        ] {
            expect(!html.contains(removedControl),
                   "Settings should not expose action control: \(removedControl)")
        }

        // Older native events can land in a Settings web view that was already
        // open during an update. Global no-op receivers make that harmless.
        for receiver in [
            "starterActionJobUpdated", "starterActionJobProgress",
            "starterActionJobError", "actionJobImportStarted",
            "actionJobImported", "actionJobPreviewing", "actionJobAccepted",
            "actionJobError",
        ] {
            expect(html.contains("function \(receiver)(){}"),
                   "Settings should retain a harmless callback: \(receiver)")
        }

        expect(bridge.contains("queuePostInstallStarterActions(") &&
               bridge.contains("startStarterActionPack(characterID: characterID, quality: .medium)"),
               "starter actions should remain automatic post-install work")
        expect(html.contains("STYLE_TUNING_MIMO_V2") &&
               html.contains("细腻高分辨率像素画") &&
               html.contains("白衣伴灵画风（默认）"),
               "Studio should retain the approved Mimo v2 default style")
        expect(html.contains("const MAX_PET_REFERENCES=8") &&
               html.contains("function scheduleCandidateAutoGeneration()") &&
               html.contains("function enqueuePetImageData") &&
               bridge.contains("PetReferenceImportQueue"),
               "multi-photo imports should remain bounded and auto-start after settling")
        expect(!html.contains("petConfirmReferences") &&
               !bridge.contains("case \"petConfirmReferences\"") &&
               html.contains("role=\"radiogroup\"") &&
               html.contains("draftFeedback:draftFeedbackForBridge") &&
               html.contains("quality:'medium'"),
               "generation should flow directly to one manually selected Medium final")

        print("starter action UI removal contract tests passed")
    }
}
