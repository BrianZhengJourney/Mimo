// sources: starter_action.swift pet_provider.swift custom_pet.swift character_sheet.swift action_sheet.swift generation_draft.swift generation_ledger.swift style_reference.swift reference_preprocessor.swift pet_generation.swift diy_style_preset.swift
import Cocoa

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct DIYStylePresetTests {
    static func main() {
        let expectedIDs = [
            "mimo-v2", "compact-cute", "source-faithful",
            "warm-storybook", "cool-confident",
        ]
        expect(DIYStylePresetID.allCases.map(\.rawValue) == expectedIDs,
               "preset IDs and order are a persisted Settings contract")
        expect(DIYStylePreset.all.map { $0.id.rawValue } == expectedIDs,
               "Settings presets should follow the canonical ID order")

        let defaults = DIYStylePreset.all.filter(\.isDefault)
        expect(defaults.count == 1 && defaults[0].id == .mimoV2,
               "exactly one Mimo v2 preset should be canonical default")
        expect(DIYStylePreset.defaultPreset.id == .mimoV2,
               "defaultPreset should resolve the canonical default")
        expect(DIYStylePreset.defaultPreset.tuningNoteZh
               == PetVisualTuningNote.detectedPersonDefault(language: "zh") &&
               DIYStylePreset.defaultPreset.tuningNoteEn
               == PetVisualTuningNote.detectedPersonDefault(language: "en"),
               "the default must remain the approved Mimo v2 tuning prompt")
        expect(DIYStylePreset.resolve(nil).id == .mimoV2 &&
               DIYStylePreset.resolve("unknown").id == .mimoV2 &&
               DIYStylePreset.resolve("warm-storybook").id == .warmStorybook,
               "preset lookup should fail closed to the canonical default")
        expect(DIYStylePreset.all.filter(\.isRecommended).count >= 4,
               "the default and at least three alternatives should be recommended")

        let forbidden = [
            "identity", "reference", "subject", "person", "woman", "girl",
            "face", "skin", "hair", "outfit", "clothes", "panel", "layout",
            "margin", "matte", "background", "transparent", "alpha",
            "watermark", "logo", "prompt", "instruction", "safety",
            "身份", "参考", "主体", "人物", "女人", "女孩", "脸", "肤色",
            "发型", "头发", "服装", "衣服", "面板", "布局", "边距", "抠图",
            "背景", "透明", "水印", "标志", "提示词", "指令", "安全",
        ]
        for preset in DIYStylePreset.all {
            expect(!preset.labelZh.isEmpty && !preset.labelEn.isEmpty,
                   "preset labels must be bilingual")
            for note in [preset.tuningNoteZh, preset.tuningNoteEn] {
                expect(!note.isEmpty && note == PetVisualTuningNote.sanitize(note),
                       "preset notes must be non-empty sanitized tuning data")
                expect(note.unicodeScalars.count <= PetVisualTuningNote.maximumUnicodeScalars &&
                       note.utf8.count <= PetVisualTuningNote.maximumUTF8Bytes,
                       "preset notes must fit PetVisualTuningNote bounds")
                let lowered = note.lowercased()
                for token in preset.isDefault ? [] : forbidden {
                    expect(!lowered.contains(token),
                           "preset \(preset.id.rawValue) leaked forbidden token \(token)")
                }
            }
            expect(preset.tuningNote(language: "zh") == preset.tuningNoteZh &&
                   preset.tuningNote(language: "en") == preset.tuningNoteEn,
                   "localized tuning-note lookup should be deterministic")
        }

        let runtime = DIYStylePreset.runtimeDictionaries
        expect(runtime.count == expectedIDs.count,
               "Settings runtime dictionaries should expose every preset")
        for (index, preset) in DIYStylePreset.all.enumerated() {
            let row = runtime[index]
            expect(row["id"] as? String == preset.id.rawValue &&
                   row["labelZh"] as? String == preset.labelZh &&
                   row["labelEn"] as? String == preset.labelEn &&
                   row["tuningNoteZh"] as? String == preset.tuningNoteZh &&
                   row["tuningNoteEn"] as? String == preset.tuningNoteEn &&
                   row["isDefault"] as? Bool == preset.isDefault &&
                   row["isRecommended"] as? Bool == preset.isRecommended,
                   "runtime dictionary should preserve preset \(preset.id.rawValue)")
        }

        print("DIY style preset tests passed")
    }
}
