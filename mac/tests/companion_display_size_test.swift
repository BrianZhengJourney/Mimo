// sources: companion_geometry.swift companion_physics.swift
import CoreGraphics

@main
struct CompanionDisplaySizeTests {
    static func expectClose(_ actual: CGFloat, _ expected: CGFloat,
                            _ label: String) {
        precondition(abs(actual - expected) < 0.001,
                     "\(label): expected \(expected), got \(actual)")
    }

    static func main() {
        expectClose(
            CompanionDisplaySize.nativeHeight(percent: 100), 240,
            "default preserves the current native size")
        expectClose(
            CompanionDisplaySize.nativeHeight(percent: 60), 144,
            "minimum scale is useful but still readable")
        expectClose(
            CompanionDisplaySize.nativeHeight(percent: 140), 336,
            "maximum scale remains inside the supported overlay range")
        expectClose(
            CompanionDisplaySize.clampedPercent(20), 60,
            "values below the slider clamp")
        expectClose(
            CompanionDisplaySize.clampedPercent(200), 140,
            "values above the slider clamp")
        expectClose(
            CompanionDisplaySize.clampedPercent(.infinity), 100,
            "non-finite values return to the default")
        print("companion display size tests passed")
    }
}
