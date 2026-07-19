// sources: 
// compile-only: diagnostic CLI; not safe to run unattended
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2,
      let pid = Int32(CommandLine.arguments[1]) else {
    fputs("usage: app_lifecycle_probe <pid> [--expect-settings]\n", stderr)
    exit(2)
}

let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

let owned = windows.filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
}
for window in owned {
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("id=\(number) layer=\(layer) onscreen=\(onScreen) name=\(name.debugDescription) bounds=\(bounds)")
}

if CommandLine.arguments.contains("--expect-settings") {
    let hasSettings = owned.contains { window in
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        let layer = window[kCGWindowLayer as String] as? Int ?? -1
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        return onScreen && layer == 0 && width >= 500 && height >= 700
    }
    if !hasSettings {
        fputs("expected a visible Settings window\n", stderr)
        exit(1)
    }
}
