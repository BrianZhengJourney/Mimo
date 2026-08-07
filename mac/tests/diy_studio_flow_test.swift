// sources: starter_action.swift
import Foundation

private func count(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var result = 0
    var cursor = haystack.startIndex
    while let range = haystack.range(
        of: needle, range: cursor..<haystack.endIndex
    ) {
        result += 1
        cursor = range.upperBound
    }
    return result
}

private func javascriptArray(named name: String, in source: String) -> String? {
    guard let start = source.range(of: "const \(name)=[")?.upperBound,
          let end = source.range(
            of: "];", range: start..<source.endIndex)?.lowerBound else {
        return nil
    }
    return String(source[start..<end])
}

@main
struct DIYStudioFlowTests {
    static func main() throws {
        var failures: [String] = []
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)

        require(settings.contains("const MAX_PET_REFERENCES=8") &&
                settings.contains("MAX_PET_REFERENCES-petLab.references.length") &&
                settings.contains("function enqueuePetImageData"),
                "Studio should retain one bounded eight-image reference set")
        require(settings.contains("function scheduleCandidateAutoGeneration()") &&
                settings.contains("candidateAutoGenerateSignature") &&
                settings.contains("S.openAIConfigured") &&
                settings.contains("referencesImporting()"),
                "settled imports should schedule one deduplicated automatic draft run")
        require(settings.contains("temperamentID:petLab.temperamentID,likeness:0.70") &&
                !settings.contains("likeness:0.58"),
                "the hidden likeness control should use the approved 0.70 default")
        require(settings.contains("data-zh=\"生成 3 个草稿\"") &&
                settings.contains("data-en=\"Generate 3 drafts\"") &&
                settings.contains("重新生成 3 个草稿"),
                "one explicit fallback should generate or regenerate three drafts")

        require(!settings.contains("id=\"actionImportSection\"") &&
                !settings.contains("id=\"actionReview\"") &&
                !settings.contains("Starter Actions · DIY 动作"),
                "action generation should not have a visible Settings surface")
        for control in [
            "renderActionReview", "starterActionCards", "startStarterAction",
            "startDefaultStarterActions", "requestActionBundle",
            "previewActionJob", "acceptActionJob", "petStarterActionStartDefaults",
        ] {
            require(!settings.contains(control),
                    "removed action control should stay absent: \(control)")
        }
        for receiver in [
            "starterActionJobUpdated", "starterActionJobProgress",
            "starterActionJobError", "actionJobImportStarted",
            "actionJobImported", "actionJobPreviewing", "actionJobAccepted",
            "actionJobError",
        ] {
            require(settings.contains("function \(receiver)"),
                    "native callback receiver should remain harmless: \(receiver)")
        }

        for removed in [
            "id=\"petLikeness\"", "id=\"qualityGrid\"",
            "id=\"studioSteps\"", "id=\"studioTotalPrice\"",
            "selectImageQuality(", "function referenceReviewHTML",
            "function confirmPetReferences", "确认主角 · 开始 Low 生成",
        ] {
            require(!settings.contains(removed),
                    "obsolete DIY choice or confirmation should be absent: \(removed)")
        }
        require(!settings.contains("function petReferencePreview") &&
                !settings.contains("type:'petConfirmReferences'"),
                "native preprocessing should continue without a Web UI confirmation round-trip")

        require(!settings.contains("candidateIndices") &&
                !settings.contains("evolutionQueue") &&
                !settings.contains("batchResults") &&
                settings.contains("candidateIndex:null"),
                "draft selection should be singular with no batch queue")
        require(settings.contains("role=\"radiogroup\"") &&
                settings.contains("role=\"radio\"") &&
                settings.contains("function selectCandidate(index)"),
                "the three drafts should behave as a single-choice group")
        require(settings.contains("candidateFeedback:{}") &&
                settings.contains("function updateCandidateFeedback(index,value)") &&
                settings.contains("class=\"candidate-feedback\"") &&
                settings.contains("maxlength=\"160\"") &&
                settings.contains("draftFeedback:draftFeedbackForBridge"),
                "each indexed draft should keep one bounded feedback note")

        require(settings.contains("class=\"candidate-lightbox\"") &&
                settings.contains("function openCandidateLightbox(index)") &&
                settings.contains("event.target===this") &&
                settings.contains("event.key==='Escape'"),
                "draft zoom should close from the backdrop and Escape")
        require(count("id=\"petEvolutionGenerate\"", in: settings) == 1 &&
                count("onclick=\"generateEvolution()\"", in: settings) == 1 &&
                settings.contains("candidateIndex:index") &&
                settings.contains("quality:'medium'"),
                "one final CTA should send one draft and fixed Medium quality")
        require(settings.contains("function installCharacterSheet()") &&
                settings.contains("type:'petInstallRaster'"),
                "the simplified final result should remain installable")

        let presets = javascriptArray(named: "DIY_STYLE_PRESETS", in: settings)
        require(presets != nil, "Studio should preserve the style preset catalog")
        if let presets {
            require(count("default:true", in: presets) == 1,
                    "style catalog should have one default")
            require(count("recommended:true", in: presets) >= 3,
                    "style catalog should retain recommended alternatives")
        }
        require(settings.contains("id=\"petStyleTuning\"") &&
                settings.contains("updateStyleTuning(this.value)"),
                "preset notes should remain freely editable")

        require(settings.contains("id=\"petReferenceDropCue\"") &&
                settings.contains("松手，加入参考图") &&
                settings.contains("Drop to add") &&
                settings.contains("从 Google 图片、网页或 Finder 直接拖进来"),
                "DIY should explain and visibly acknowledge cross-app image drops")
        require(settings.contains("function petDropURLCandidates(dataTransfer)") &&
                settings.contains("dataTransfer.getData('text/html')") &&
                settings.contains("dataTransfer.getData('text/uri-list')") &&
                settings.contains("url.searchParams.get(key)") &&
                settings.contains("['imgurl','mediaurl']") &&
                settings.contains("function addPetReferenceDrop(dataTransfer)") &&
                settings.contains("sendStudio({type:'petWebReference'") &&
                settings.contains("addPetReferenceFiles(dataTransfer?.files)"),
                "one drop path should accept both browser URLs/HTML and Finder files")
        require(settings.contains("blob:") &&
                settings.contains("打开原图再拖") &&
                settings.contains("Open the original image and drag it again"),
                "temporary browser-only image URLs should fail with a useful recovery")

        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("DIY Studio simplified-flow contract tests passed")
    }
}
