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
        for key in ["recentIDs", "activeIDs", "archivedIDs", "categories", "metadata"] {
            expect(product.contains("\"\(key)\""),
                   "native Settings state should include canonical pet-library \(key)")
        }
        expect(product.contains("PetLibraryStateStore.shared") &&
               product.contains("petLibraryPayload(customPets: customPets)"),
               "native code should own persisted library ordering and metadata")
        expect(product.contains("row[\"displayName\"] = displayName"),
               "native metadata should expose the persisted familiar alias")
        expect(product.contains("markPetLibraryUsed(id)") &&
               product.contains("markPetLibraryUsed(characterID)") &&
               product.contains("markPetLibraryUsed(\"prototype\")"),
               "pick and every adoption path should update persisted recency")

        expect(occurrences("id=\"petLibraryToggle\"", in: settings) == 1 &&
               settings.contains("onclick=\"togglePetLibrary()\"") &&
               settings.contains("tx('收起','Collapse')") &&
               settings.contains("tx('展开','Expand')"),
               "Your Familiar should have one clear Collapse/Expand toggle")
        expect(settings.contains("const petLibraryUI={expanded:false") &&
               settings.contains("library.recentIDs.slice(0,3)"),
               "the collapsed default should render native's three recent IDs")

        let libraryRendering = section(
            settings, from: "function petLibraryItem(", to: "const filters =")
        expect(libraryRendering.contains("library.activeIDs") &&
               libraryRendering.contains("library.archivedIDs") &&
               libraryRendering.contains("library.metadata") &&
               !libraryRendering.contains(".sort("),
               "JS should filter native canonical IDs without inventing order")
        expect(libraryRendering.contains("pet-library-filter") &&
               libraryRendering.contains("setPetLibraryCategory") &&
               libraryRendering.contains("setPetLibraryView('archived')"),
               "expanded library should expose compact category and hidden filters")

        expect(settings.contains("function renamePet(") &&
               settings.contains("type:'petLibraryRename'") &&
               libraryRendering.contains("const rename=`") &&
               libraryRendering.contains("renamePet('") &&
               libraryRendering.contains("metadata.displayName||m.name"),
               "every built-in, legacy, and DIY familiar should expose its alias and rename action")
        expect(settings.contains("function editPetCategory(") &&
               settings.contains("type:'petLibraryCategory'") &&
               libraryRendering.contains("card-category"),
               "every pet should support a free-text category filing label")
        expect(settings.contains("type:'petLibraryArchive'") &&
               settings.contains("type:'petLibraryUnarchive'") &&
               libraryRendering.contains("tx('隐藏','Hide')") &&
               libraryRendering.contains("tx('恢复','Restore')"),
               "cards should offer reversible Hide and Restore")
        expect(!settings.contains("class=\"card-delete\"") &&
               !libraryRendering.contains("removeCustomPet("),
               "permanent deletion should not be a visible card action")

        expect(product.contains("case \"petLibraryRename\", \"petRename\"") &&
               product.contains("customPetStore.rename(") &&
               product.contains("setDisplayName(displayName, for: characterID)"),
               "native rename should persist every alias, sync DIY manifests, and retain compatibility")
        expect(product.contains("case \"petLibraryCategory\"") &&
               product.contains("case \"petLibraryArchive\"") &&
               product.contains("case \"petLibraryUnarchive\"") &&
               product.contains("Keep at least one familiar visible."),
               "native bridge should validate filing and preserve one visible familiar")
        expect(settings.contains("var(--surface-raised)") &&
               settings.contains("var(--accent-soft)"),
               "the compact library should reuse Mimo's warm minimal surface tokens")

        print("pet library UI tests passed")
    }
}
