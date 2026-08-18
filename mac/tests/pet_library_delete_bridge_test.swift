// sources: pet_library.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func occurrences(_ needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
}

@main
struct PetLibraryDeleteBridgeTests {
    static func main() throws {
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let customStore = try String(
            contentsOfFile: "mac/custom_pet.swift", encoding: .utf8)
        let actionStore = try String(
            contentsOfFile: "mac/action_generation_job.swift", encoding: .utf8)
        let starterStore = try String(
            contentsOfFile: "mac/starter_action_job.swift", encoding: .utf8)

        expect(product.contains("case \"petLibraryDelete\", \"petDelete\"")
               && product.contains("deletePetLibraryCharacter(characterID)"),
               "Settings should expose the new deletion message and legacy alias")
        expect(product.contains("case \"petLibraryUpdate\"")
               && product.contains("updatePetLibraryCharacter(")
               && product.contains("settingsCall(\"petLibraryUpdated\""),
               "name and category should save through one atomic manager bridge")
        expect(!product.contains("famSetCustomPet(\\(json), false)")
               && occurrences("famSetCustomPet(\\(json))", in: product) == 1,
               "only adoption may select a custom familiar; edits and action installs only register it")
        expect(product.contains("settingsCall(\"petLibraryDeleted\"")
               && product.contains("\"deletesAt\": ISO8601DateFormatter()"),
               "successful deletion should explicitly close the Settings transaction")
        expect(product.contains("reportPetLibraryError(error, characterID: characterID)")
               && product.contains("settingsCall(\"petLibraryError\""),
               "all deletion failures should return through petLibraryError")
        expect(product.contains("try $0.moveToTrash(characterID, at: deletedAt)")
               && product.contains("case \"petLibraryRestoreDeleted\"")
               && product.contains("restoreDeletedPetLibraryCharacter(characterID)"),
               "deletion should enter a reversible seven-day state for every familiar")
        expect(product.contains("stopPetWorkForDeletion(characterID: canonicalID)")
               && product.contains("purgeExpiredPetLibraryDeletions(now: Date = Date())")
               && product.contains("library.expiredDeletedCharacterIDs(now: now)")
               && product.contains("try customPetStore.delete(characterID: canonicalID)")
               && product.contains("actionGenerationJobStore.deleteJobs(characterID: canonicalID)")
               && product.contains("starterActionJobStore.deleteJobs(characterID: canonicalID)")
               && !product.contains("try? actionGenerationJobStore.deleteJobs(characterID: canonicalID)")
               && !product.contains("try? starterActionJobStore.deleteJobs(characterID: canonicalID)"),
               "custom deletion should cancel producers immediately but purge assets and jobs only at expiry")
        expect(product.contains("Mimo pet library restore fail-closed")
               && product.contains("Mimo pet library fail-closed")
               && product.contains("PetLibraryStateStore.shared.load()")
               && product.contains(".isSelectable(characterID)"),
               "corrupt lifecycle state and custom work entry points should fail closed")
        expect(product.contains("settingsCall(\"petExpressionCancelled\"")
               && product.contains("endExpressionRun(continuePostInstallActions: false)"),
               "deleting during expression generation should clear Settings' busy state")
        expect(product.contains("famUnregisterCustomPet")
               && product.contains("famSetCharacter")
               && product.contains("refreshNativeCompanion()"),
               "deleting the selected familiar should refresh both web and native runtimes")
        expect(product.contains(
            "let currentID = defaults.string(forKey: \"character\") ?? \"lulu\"")
               && product.contains("let isCurrent = currentID == characterID"),
               "fresh installs should treat the app-wide lulu default as current")
        expect(customStore.contains("func validateDeletionTarget(characterID: String)")
               && customStore.contains("func delete(characterID: String) throws"),
               "custom assets should cross a validated store-owned deletion boundary")
        expect(actionStore.contains("func deleteJobs(characterID: String) throws -> Int")
               && starterStore.contains("func deleteJobs(characterID: String) throws -> Int"),
               "both durable action stores should implement character-scoped cleanup")

        print("pet library delete bridge tests passed")
    }
}
