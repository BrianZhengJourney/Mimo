import Foundation

enum MimoSettingsFontFamily: String, CaseIterable {
    case pingfang
    case system
    case rounded
}

enum MimoSettingsFontWeight: String, CaseIterable {
    case regular
    case medium
    case semibold
}

/// Canonical, persisted typography choices for the Settings surface.
/// Raw CSS values never cross the native bridge.
struct MimoSettingsTypography: Equatable {
    static let familyDefaultsKey = "settingsFontFamily"
    static let weightDefaultsKey = "settingsFontWeight"

    let family: MimoSettingsFontFamily
    let weight: MimoSettingsFontWeight

    init(family: String?, weight: String?) {
        self.family = family.flatMap(MimoSettingsFontFamily.init(rawValue:)) ?? .pingfang
        self.weight = weight.flatMap(MimoSettingsFontWeight.init(rawValue:)) ?? .regular
    }

    var stateDictionary: [String: String] {
        [
            Self.familyDefaultsKey: family.rawValue,
            Self.weightDefaultsKey: weight.rawValue,
        ]
    }
}
