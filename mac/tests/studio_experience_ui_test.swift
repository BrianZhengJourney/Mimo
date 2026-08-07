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

        expect(html.contains("S.openAIStored=!!state.openAIStored")
               && html.contains("keychain-needs-authorization")
               && html.contains("已保存 · 需要重新授权")
               && html.contains("Saved · authorization needed")
               && html.contains("type:'petAuthorizeKey'")
               && html.contains("重新授权并继续")
               && html.contains("Authorize & continue"),
               "a stored-but-unreadable Keychain key should have one honest recovery path")
        expect(product.contains("case \"petAuthorizeKey\"")
               && product.contains("petKeyAuthorizationStarted")
               && product.contains("MimoSecret.openAI.read() != nil")
               && product.contains("openAIKeyStatePayload("),
               "native Settings should authorize the existing key without asking users to re-enter it")
        expect(generation.contains("case keychainNeedsAuthorization = \"keychain-needs-authorization\"")
               && generation.contains("var isReady: Bool")
               && generation.contains("var isStored: Bool")
               && generation.contains("interactionNotAllowed = true"),
               "credential readiness must be based on a non-interactive value read, not item existence")

        print("studio experience UI tests passed")
    }
}
