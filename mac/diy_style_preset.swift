import Foundation

/// Persisted IDs used by Settings. Keep order stable when adding future presets.
enum DIYStylePresetID: String, CaseIterable {
    case mimoV2 = "mimo-v2"
    case compactCute = "compact-cute"
    case sourceFaithful = "source-faithful"
    case warmStorybook = "warm-storybook"
    case coolConfident = "cool-confident"
}

/// A bounded aesthetic preference that can be safely passed through the
/// existing visual-tuning channel. Presets deliberately contain no identity,
/// reference-priority, layout, extraction, or safety instructions.
struct DIYStylePreset: Equatable {
    static let canonicalDefaultID: DIYStylePresetID = .mimoV2

    let id: DIYStylePresetID
    let labelZh: String
    let labelEn: String
    let tuningNoteZh: String
    let tuningNoteEn: String
    let isRecommended: Bool

    var isDefault: Bool { id == Self.canonicalDefaultID }

    private init(
        id: DIYStylePresetID,
        labelZh: String,
        labelEn: String,
        tuningNoteZh: String,
        tuningNoteEn: String,
        isRecommended: Bool = true
    ) {
        let safeZh = PetVisualTuningNote.sanitize(tuningNoteZh)
        let safeEn = PetVisualTuningNote.sanitize(tuningNoteEn)
        precondition(!safeZh.isEmpty && !safeEn.isEmpty,
                     "DIY style preset notes must satisfy PetVisualTuningNote")
        self.id = id
        self.labelZh = labelZh
        self.labelEn = labelEn
        self.tuningNoteZh = safeZh
        self.tuningNoteEn = safeEn
        self.isRecommended = isRecommended
    }

    func label(language: String) -> String {
        language == "en" ? labelEn : labelZh
    }

    func tuningNote(language: String) -> String {
        language == "en" ? tuningNoteEn : tuningNoteZh
    }

    var runtimeDictionary: [String: Any] {
        [
            "id": id.rawValue,
            "labelZh": labelZh,
            "labelEn": labelEn,
            "tuningNoteZh": tuningNoteZh,
            "tuningNoteEn": tuningNoteEn,
            "isDefault": isDefault,
            "isRecommended": isRecommended,
        ]
    }

    static let all: [DIYStylePreset] = [
        DIYStylePreset(
            id: .mimoV2,
            labelZh: "白衣伴灵画风（默认）",
            labelEn: "White-outfit Familiar (Default)",
            // This is the already-approved white-outfit Mimo v2 rendering
            // note. It describes finish and proportions only; the generation
            // contract separately protects the uploaded subject's identity.
            tuningNoteZh: PetVisualTuningNote.detectedPersonDefault(language: "zh"),
            tuningNoteEn: PetVisualTuningNote.detectedPersonDefault(language: "en")),
        DIYStylePreset(
            id: .compactCute,
            labelZh: "萌系短矮",
            labelEn: "Compact Cute",
            tuningNoteZh: "更萌、更短矮紧凑，头身比略可爱，四肢轻巧，轮廓圆润但不胖；表情亲和，细节清楚，避免夸张幼态与巨头比例。",
            tuningNoteEn: "Extra cute and compact; gently larger head, short light limbs, rounded but not chubby shape, friendly expression and clear detail; no extreme baby proportions."),
        DIYStylePreset(
            id: .sourceFaithful,
            labelZh: "贴近原图",
            labelEn: "Source Faithful",
            tuningNoteZh: "降低风格化偏移，准确保留已有的形状、配色、比例与细节，只做克制简化；像素密度均匀，轮廓干净，明暗自然。",
            tuningNoteEn: "Restrained stylization: keep existing shapes, colors, proportions and small details accurate; use clean contours, even pixel density and subtle shading."),
        DIYStylePreset(
            id: .warmStorybook,
            labelZh: "暖绘本",
            labelEn: "Warm Storybook",
            tuningNoteZh: "暖色绘本质感，柔和低对比配色，纸张般温润的色阶与轻柔阴影；轮廓清楚，细节精致，整体安静、亲切、有手绘温度。",
            tuningNoteEn: "Warm storybook feel with a soft low-contrast palette, paper-like color steps and gentle shadows; clean contours, delicate detail and calm handmade warmth."),
        DIYStylePreset(
            id: .coolConfident,
            labelZh: "酷感自信",
            labelEn: "Cool & Confident",
            tuningNoteZh: "更酷、更利落自信；姿态感挺拔，轮廓简洁，明暗对比略强，配色克制，神情沉稳带一点小傲气，避免攻击性与夸张肌肉。",
            tuningNoteEn: "Cool and self-assured; upright bearing, clean silhouette, firm contrast, restrained color and subtly cocky calm; avoid aggression or exaggerated muscle."),
    ]

    static var defaultPreset: DIYStylePreset {
        all.first(where: \.isDefault) ?? all[0]
    }

    static func resolve(_ rawID: String?) -> DIYStylePreset {
        guard let rawID else { return defaultPreset }
        let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let id = DIYStylePresetID(rawValue: normalized),
              let preset = all.first(where: { $0.id == id }) else {
            return defaultPreset
        }
        return preset
    }

    static var runtimeDictionaries: [[String: Any]] {
        all.map(\.runtimeDictionary)
    }
}
