// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct StudioExperienceUITests {
    static func main() throws {
        let html = try String(contentsOfFile: "mac/settings.html", encoding: .utf8)
        let product = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)
        let generation = try String(contentsOfFile: "mac/pet_generation.swift", encoding: .utf8)

        expect(html.contains("页面会留在这里")
               && html.contains("This page stays open")
               && !html.contains("continueStudioInBackground")
               && !html.contains("petContinueInBackground"),
               "starting a Studio request should keep the generation page visible")
        expect(!product.contains("case \"petContinueInBackground\"")
               && product.contains("func windowWillClose")
               && product.contains("backgroundStudioRequests.insert(requestID)"),
               "only a real window close should hand an active request to the background")

        expect(html.contains("generateCandidateVariations")
               && html.contains("petGenerateVariations")
               && html.contains("再来 3 个小表情")
               && html.contains("3 more expressions"),
               "a selected protagonist should expose an explicit three-variation affordance")
        expect(product.contains("case \"petGenerateVariations\"")
               && generation.contains("candidateVariationBoardRequest")
               && generation.contains("MICRO EXPRESSION VARIATIONS")
               && generation.contains("same locked character"),
               "variation generation should preserve the selected master through a dedicated prompt")

        expect(product.contains("queuePostInstallStarterActions(")
               && product.contains("resumePostInstallStarterActions()")
               && product.contains("startExpressionRun(")
               && product.contains("startStarterActionPack(characterID: characterID, quality: .medium)"),
               "post-adoption expressions and starter actions should remain a durable background pipeline")

        print("studio experience UI tests passed")
    }
}
