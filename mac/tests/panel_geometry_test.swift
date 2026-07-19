// sources: panel_geometry.swift
import Cocoa

@main
struct PanelGeometryTests {
    static func expect(_ actual: NSPoint, _ expected: NSPoint, _ label: String) {
        precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
    }

    static func main() {
        let size = NSSize(width: 560, height: 320)
        let main = NSRect(x: 0, y: 0, width: 1728, height: 1084)
        let fallback = NSPoint(x: 1156, y: 4)

        expect(recoveredPanelOrigin(saved: NSPoint(x: 900, y: 500), fallback: fallback,
                                    size: size, visibleFrames: [main]),
               NSPoint(x: 900, y: 500), "keeps a visible origin")
        expect(recoveredPanelOrigin(saved: NSPoint(x: 1650, y: 1000), fallback: fallback,
                                    size: size, visibleFrames: [main]),
               NSPoint(x: 1168, y: 764), "clamps a barely-intersecting transparent panel")
        expect(recoveredPanelOrigin(saved: NSPoint(x: 3000, y: 2000), fallback: fallback,
                                    size: size, visibleFrames: [main]),
               fallback, "recovers a fully disconnected display")

        let external = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        expect(recoveredPanelOrigin(saved: NSPoint(x: -700, y: 400), fallback: fallback,
                                    size: size, visibleFrames: [main, external]),
               NSPoint(x: -700, y: 400), "keeps an origin on a connected external display")
        print("panel geometry tests passed")
    }
}
