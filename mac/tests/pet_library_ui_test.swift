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
    var count = 0
    var cursor = text.startIndex
    while let range = text.range(of: needle, range: cursor..<text.endIndex) {
        count += 1
        cursor = range.upperBound
    }
    return count
}

private func section(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start)?.lowerBound,
          let upper = text.range(of: end, range: lower..<text.endIndex)?.lowerBound
    else { return "" }
    return String(text[lower..<upper])
}

@main
struct PetLibraryUITests {
    static func main() throws {
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let product = try String(
            contentsOfFile: "mac/product.swift", encoding: .utf8)
        let common = try String(
            contentsOfFile: "mac/common.sh", encoding: .utf8)

        expect(common.contains("custom_pet.swift\n  pet_library.swift"),
               "the app target should compile the independent pet-library state")
        for key in ["recentIDs", "activeIDs", "archivedIDs", "deletedIDs", "categories", "metadata"] {
            expect(product.contains("\"\(key)\""),
                   "native Settings state should include canonical pet-library \(key)")
        }
        expect(product.contains("PetLibraryStateStore.shared") &&
               product.contains("petLibraryPayload(customPets: customPets)"),
               "native code should own persisted library ordering and metadata")
        expect(product.contains("row[\"displayName\"] = displayName"),
               "native metadata should expose the persisted familiar alias")
        expect(!product.contains("markPetLibraryUsed(id)") &&
               product.contains("case \"petLibraryReorder\"") &&
               product.contains("setActiveOrder(orderedCharacterIDs") &&
               product.contains("settingsCall(\"petLibraryReorderFailed\"") &&
               product.contains("\"requestID\": requestID") &&
               product.contains("try $0.markUsed(\"prototype\")"),
               "selection should not reorder cards; only the reorder bridge persists order")

        expect(occurrences("id=\"petLibraryToggle\"", in: settings) == 1 &&
               settings.contains("onclick=\"togglePetLibrary()\"") &&
               settings.contains("tx('收起','Collapse')") &&
               settings.contains("tx('展开','Expand')"),
               "Your Familiar should have one clear Collapse/Expand toggle")
        expect(settings.contains("const petLibraryUI={expanded:false") &&
               settings.contains("Array.isArray(library.visibleRecentIDs)") &&
               settings.contains("return recent.slice(0,3)") &&
               settings.contains("library.visibleActiveIDs"),
               "Your Familiar should render native's individual IDs")
        expect(product.contains("\"visibleRecentIDs\": recentIDs") &&
               product.contains("\"visibleActiveIDs\": activeIDs") &&
               !product.contains("PetLibraryVariationDisplay") &&
               !product.contains("variationGroupByID"),
               "native state should expose every same-name familiar as an individual card")

        let libraryRendering = section(
            settings, from: "function petLibraryItem(", to: "const filters =")
        expect(libraryRendering.contains("library.visibleActiveIDs") &&
               libraryRendering.contains("S.petLibrary?.activeIDs") &&
               libraryRendering.contains("library.archivedIDs") &&
               libraryRendering.contains("library.deletedIDs") &&
               libraryRendering.contains("library.metadata") &&
               !libraryRendering.contains(".sort("),
               "JS should display individual IDs while preserving native's full reorder list")
        expect(libraryRendering.contains("const visibleSet=new Set(visibleOrder)") &&
               libraryRendering.contains("visibleSet.has(id)?queue.shift():id") &&
               settings.contains("visibleActiveIDs=pending.activeIDs.slice()") &&
               settings.contains("visibleRecentIDs=pending.recentIDs.slice()"),
               "dragging a filtered card should move only that individual familiar")
        expect(!settings.contains("card-stack-count") &&
               !settings.contains("function petLibraryVariationMembers(") &&
               !settings.contains("function openPetLibraryVariationTray(") &&
               !settings.contains("id=\"petVariationTray\"") &&
               !settings.contains("selectPetLibraryVariation"),
               "same-name familiars should stay expanded without stacking or version trays")
        expect(libraryRendering.contains("pet-library-filter") &&
               libraryRendering.contains("setPetLibraryCategory") &&
               libraryRendering.contains("setPetLibraryView('archived')") &&
               libraryRendering.contains("setPetLibraryView('trash')"),
               "expanded library should expose category, Hidden, and Recently Deleted filters")

        expect(libraryRendering.contains("const manage=`") &&
               libraryRendering.contains("class=\"card-manage\"") &&
               libraryRendering.contains("openPetManager('") &&
               libraryRendering.contains("metadata.displayName||m.name") &&
               libraryRendering.contains("pick(event,'${characterID}')") &&
               libraryRendering.contains("startPetLibraryDrag") &&
               libraryRendering.contains("dropPetLibraryCard") &&
               libraryRendering.contains("type:'petLibraryReorder',requestID,orderedCharacterIDs") &&
               libraryRendering.contains("petLibraryReorderFailed") &&
               libraryRendering.contains("pending.timeout=setTimeout") &&
               libraryRendering.contains("Date.now()<petLibraryDrag.suppressPickUntil") &&
               !libraryRendering.contains("card-rename") &&
               !libraryRendering.contains("card-library-action") &&
               !libraryRendering.contains("card-category"),
               "cards should select without reordering and expose drag ordering plus one management entry")

        expect(settings.contains("id=\"petManagerOverlay\"") &&
               settings.contains("role=\"dialog\" aria-modal=\"true\"") &&
               settings.contains("onclick=\"if(event.target===this)closePetManager()\"") &&
               settings.contains("if(manager&&!manager.hidden)closePetManager()") &&
               !settings.contains("window.prompt(") &&
               !settings.contains("window.confirm(") &&
               !settings.contains("window.alert("),
               "familiar management should use an in-page sheet that dismisses outside or with Escape")
        expect(settings.contains("id=\"petManagerName\"") &&
               settings.contains("function savePetManager(") &&
               settings.contains("id=\"petManagerCategory\"") &&
               settings.contains("list=\"petManagerCategoryOptions\"") &&
               settings.contains("S.petLibrary?.categories||[]") &&
               settings.contains("type:'petLibraryUpdate',characterID,name,category") &&
               settings.contains("function petLibraryUpdated(event)") &&
               settings.contains("function petRenamed(event)") &&
               settings.contains("function petRenameFailed(event)") &&
               settings.contains("if(event?.characterID&&event.characterID!==petManagerUI.characterID)return") &&
               !settings.contains("send({type:'petLibraryRename'") &&
               !settings.contains("send({type:'petLibraryCategory'"),
               "one atomic manager update should persist names and typed or existing categories without partial saves")
        expect(settings.contains("type:archived?'petLibraryUnarchive':'petLibraryArchive'") &&
               settings.contains("tx('恢复到已隐藏','Restore to Hidden')") &&
               settings.contains("tx('恢复伴灵','Restore familiar')") &&
               settings.contains("archived?tx('取消隐藏','Unhide'):tx('隐藏','Hide')"),
               "the manager should keep Hide separate from deleted-item restoration")
        expect(settings.contains("id=\"petDeleteConfirm\"") &&
               settings.contains("移到最近删除") &&
               settings.contains("7 天内可以恢复") &&
               settings.contains("type:'petLibraryRestoreDeleted',characterID") &&
               settings.contains("managedPetMetadata().deleted===true") &&
               settings.contains("function dispatchPetManagerOperation(message)") &&
               settings.contains("petManagerUI.timeout=setTimeout") &&
               settings.contains("function setPetManagerFormDisabled(disabled)") &&
               settings.contains("form.inert=!!disabled") &&
               settings.contains("hidden=false;setPetManagerFormDisabled(true)") &&
               settings.contains("hidden=true;setPetManagerFormDisabled(false)") &&
               settings.contains("confirm.disabled=false;confirm.focus()") &&
               settings.contains("function confirmPetDelete(") &&
               settings.contains("function petLibraryDeleted(event)") &&
               settings.contains("function petLibraryDeleteFailed(event)") &&
               settings.contains("type:'petLibraryDelete'") &&
               !settings.contains("type:'petDelete'"),
               "all deletion should remain recoverable for seven days without replacing Hide")

        let adoption = section(
            settings, from: "function customPetAdopted(",
            to: "/* Expression sheets:")
        let deletionReceiver = section(
            settings, from: "function petLibraryDeleted(",
            to: "function applyPetLibraryUpdate(")
        expect(adoption.contains("adoptedCharacterID:spec.characterID") &&
               adoption.contains("source:null,sourceName:'',references:[],primaryReferenceID:null") &&
               deletionReceiver.contains("event.characterID===petLab.adoptedCharacterID") &&
               deletionReceiver.contains("adoptedCharacterID:null,adoptedName:'',status:'idle'") &&
               deletionReceiver.contains("candidateDraftID:null,candidates:[],candidateIndex:null,candidateFeedback:{}") &&
               deletionReceiver.contains("sheet:null,sheetQuality:null") &&
               deletionReceiver.contains("preservedResult:false,expr:null") &&
               deletionReceiver.contains("partialImage:null,rawPreview:null") &&
               deletionReceiver.contains("closeCandidateLightbox();renderPetLab()") &&
               !deletionReceiver.contains("references:[]") &&
               !deletionReceiver.contains("source:null") &&
               !deletionReceiver.contains("primaryReferenceID:null"),
               "adoption clears its finished references, while later deletion must not erase a new round's references")
        let expressionCancellation = section(
            settings, from: "function petExpressionCancelled(",
            to: "function petExpressionError(")
        expect(expressionCancellation.contains("petLab.expr?.characterID||petLab.adoptedCharacterID") &&
               expressionCancellation.contains("event.characterID!==currentID)return"),
               "a late expression cancellation should not clear a newer familiar's expression state")

        expect(product.contains("case \"petLibraryRename\", \"petRename\"") &&
               product.contains("customPetStore.rename(") &&
               product.contains("setDisplayName(displayName, for: characterID)"),
               "native rename should persist every alias, sync DIY manifests, and retain compatibility")
        expect(product.contains("case \"petLibraryUpdate\"") &&
               product.contains("updatePetLibraryCharacter(") &&
               product.contains("settingsCall(\"petLibraryUpdated\", event)"),
               "native should apply the manager form atomically and acknowledge the matching sheet")
        expect(product.contains("case \"petLibraryCategory\"") &&
               product.contains("case \"petLibraryArchive\"") &&
               product.contains("case \"petLibraryUnarchive\"") &&
               product.contains("case \"petLibraryRestoreDeleted\"") &&
               product.contains("purgeExpiredPetLibraryDeletions") &&
               product.contains("Keep at least one familiar visible."),
               "native bridge should validate filing, restoration, expiry, and preserve one visible familiar")
        expect(settings.contains("var(--surface-raised)") &&
               settings.contains("var(--accent-soft)"),
               "the compact library should reuse Mimo's warm minimal surface tokens")

        print("pet library UI tests passed")
    }
}
