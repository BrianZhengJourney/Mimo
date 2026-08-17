// sources: pet_library.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct PhotosPeoplePrototypeUITests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "mac/prototypes/apple-photos-people/photos_people_prototype.swift",
            encoding: .utf8)

        expect(source.contains("width: 600, height: 760") &&
               source.contains("window.minSize = NSSize(width: 540, height: 620)") &&
               source.contains("window.maxSize = NSSize(width: 660, height: 1200)"),
               "Photos people should stay a compact portrait window")
        expect(source.contains("case recent") &&
               source.contains("case favorites") &&
               source.contains("case selfies") &&
               source.contains("case portraits") &&
               source.contains(".smartAlbumFavorites") &&
               source.contains(".smartAlbumSelfPortraits") &&
               source.contains(".smartAlbumDepthEffect"),
               "public PhotoKit sources should narrow the local scan")
        expect(source.contains("addFullWidthResult(groupCard") &&
               source.contains("preview.widthAnchor.constraint(equalToConstant: 64)") &&
               source.contains("box.heightAnchor.constraint(equalToConstant: 88)") &&
               source.contains("NSImage(cgImage: group.best.face") &&
               source.contains("选择样子") &&
               source.contains("showingSingletons") &&
               source.contains("toggleSingletons"),
               "results should use compact single-column rows and fold single sightings")
        expect(source.contains("PhotosCandidatePartition") &&
               source.contains("isDisjoint(with:") &&
               source.contains("mergeIsCoherent("),
               "face grouping should use constrained clustering with same-photo exclusions")
        expect(source.contains("PHPickerViewController") &&
               source.contains("configuration.selectionLimit = 8") &&
               source.contains("configuration.selection = .ordered"),
               "the system Photos picker should provide a manual correction path")
        expect(!source.contains("window?.orderOut(nil)") &&
               source.contains("func keepVisible(alongside studioWindow: NSWindow?)") &&
               source.contains("combinedWidth <= visible.width") &&
               source.contains("func resetAfterCompletedStudioProject()") &&
               source.contains("rawCandidates.removeAll()") &&
               source.contains("groups.removeAll()") &&
               source.contains("purgeTemporaryPortraitDirectories()"),
               "photo handoff should keep its window open and release the completed person's scan")
        expect(source.contains("func reactivateAfterPhotoPicker()") &&
               source.contains("showPhotoHandoffStudio()") &&
               source.contains("revealStudioWhenFinished: true"),
               "finishing the Photos picker should reactivate Mimo and reveal Studio")
        expect(source.contains("presentPhotoSelection(for:") &&
               source.contains("PhotosAppearancePreset") &&
               source.contains("米墨推荐") &&
               source.contains("最近的样子") &&
               source.contains("自己挑") &&
               source.contains("limit: Int = 6") &&
               source.contains("selectedCandidateIDs.count < 8") &&
               source.contains("count >= 2") &&
               source.contains("PhotosFlippedStackView") &&
               source.contains("let sheetHeight = min(CGFloat(640)"),
               "choosing a person should open a bounded appearance/photo selection step")
        expect(source.contains("let tuningViews: [NSView] = modelLabEnabled") &&
               source.contains("if modelLabEnabled { controlViews.append(tuning) }") &&
               source.contains("if modelLabEnabled { controlViews.append(cloudCheckbox) }"),
               "production controls should hide model and grouping diagnostics")
        expect(source.contains("isFavorite: asset.isFavorite") &&
               source.contains("private func groupSummary(") &&
               source.contains("\\(group.candidates.count) 张照片"),
               "candidate cards should keep only the useful photo count")
        expect(source.contains("possibly the same person") &&
               !source.contains("PHPerson"),
               "the prototype should preserve an explicit identity-confidence boundary")
        expect(source.contains("showIdentityModelFailure(selectedModel)") &&
               source.contains("也不会偷偷改用旧的 Vision 分组") &&
               !source.contains("reports[selectedModel] == nil\n            ? PhotosFaceIdentityModel.vision"),
               "a missing dedicated model must never silently fall back to Vision")
    }
}
