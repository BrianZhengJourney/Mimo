import CoreGraphics
import Foundation
import ImageIO
import Vision

// The measurement that actually matches the gate's job: within ONE expression
// sheet, the three cells are the same character at the same evolution stage,
// differing only in expression — which is the closest available stand-in for
// an action sheet's nine poses. Cross-pet pairs are the negative class.
@main struct ExprCalibrate {
  static func load(_ p: String) -> CGImage? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(s, 0, nil)
  }
  static func cells(_ sheet: CGImage) -> [CGImage] {
    let w = sheet.width / 3
    return (0..<3).compactMap { sheet.cropping(to: CGRect(x: $0*w, y: 0, width: w, height: sheet.height)) }
  }
  static func fp(_ i: CGImage) -> VNFeaturePrintObservation? {
    try? ConsistencyMetric.featurePrint(of: ConsistencyMetric.cropToSubject(i) ?? i)
  }
  static func d(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
    var v = Float(0); try? a.computeDistance(&v, to: b); return v
  }
  static func main() {
    let root = ("~/Library/Application Support/Mimo/Pets" as NSString).expandingTildeInPath
    var groups: [String: [VNFeaturePrintObservation]] = [:]
    for dir in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() {
      for stage in 0..<3 {
        let path = "\(root)/\(dir)/expr-\(stage).png"
        guard FileManager.default.fileExists(atPath: path), let img = load(path) else { continue }
        let prints = cells(img).compactMap { fp($0) }
        if prints.count == 3 { groups["\(dir.prefix(8))-s\(stage)"] = prints }
      }
    }
    guard !groups.isEmpty else { print("no expression sheets found"); return }
    print("expression sheets: \(groups.keys.sorted().joined(separator: ", "))")

    var same: [Float] = [], diff: [Float] = []
    let keys = groups.keys.sorted()
    for k in keys {
      let g = groups[k]!
      for a in 0..<3 { for b in (a+1)..<3 { same.append(d(g[a], g[b])) } }
    }
    for (i, k1) in keys.enumerated() {
      for k2 in keys[(i+1)...] where k1.prefix(8) != k2.prefix(8) {
        for a in groups[k1]! { for b in groups[k2]! { diff.append(d(a, b)) } }
      }
    }
    func stats(_ xs: [Float], _ l: String) {
      guard !xs.isEmpty else { print("\(l) — none"); return }
      let s = xs.sorted()
      print(String(format: "%@ n=%d  min=%.2f  median=%.2f  max=%.2f", l, s.count, s.first!, s[s.count/2], s.last!))
    }
    stats(same, "SAME char, same stage, diff expression")
    stats(diff, "DIFFERENT characters                 ")
    if !same.isEmpty && !diff.isEmpty {
      print(String(format: "separation gap: max(same)=%.2f vs min(diff)=%.2f → %@",
                   same.max()!, diff.min()!,
                   same.max()! < diff.min()! ? "CLEAN" : "OVERLAPPING"))
    }
  }
}
