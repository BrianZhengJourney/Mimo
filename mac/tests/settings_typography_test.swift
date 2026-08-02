// sources: settings_typography.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct SettingsTypographyTests {
    static func main() {
        expect(MimoSettingsFontFamily.allCases.map(\.rawValue)
               == ["pingfang", "system", "rounded"],
               "font families should be a fixed whitelist")
        expect(MimoSettingsFontWeight.allCases.map(\.rawValue)
               == ["regular", "medium", "semibold"],
               "font weights should be a fixed whitelist")

        let defaults = MimoSettingsTypography(family: nil, weight: nil)
        expect(defaults.family == .pingfang && defaults.weight == .regular,
               "PingFang Regular should be the default")

        let selected = MimoSettingsTypography(
            family: "rounded", weight: "semibold")
        expect(selected.family == .rounded && selected.weight == .semibold,
               "valid choices should round-trip")
        expect(selected.stateDictionary == [
            "settingsFontFamily": "rounded",
            "settingsFontWeight": "semibold",
        ], "bridge state should expose canonical values")

        let rejected = MimoSettingsTypography(
            family: "url(javascript:alert(1))", weight: "950")
        expect(rejected.family == .pingfang && rejected.weight == .regular,
               "unknown CSS-like values must fail closed to defaults")

        print("settings typography tests passed")
    }
}
