import CoreGraphics
import Foundation
import ImageIO
import Vision

// Measures real generated sheets: how far apart are the three stage cells of
// one familiar (same character), versus cells from different familiars
// (different characters)? If those two distributions do not separate, the
// metric cannot gate drift no matter where the threshold is put.
@main struct Calibrate {
  static func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }
  static func cells(_ sheet: CGImage, count: Int = 3) -> [CGImage] {
    let w = sheet.width / count
    return (0..<count).compactMap {
      sheet.cropping(to: CGRect(x: $0 * w, y: 0, width: w, height: sheet.height))
    }
  }
  static func print2(_ image: CGImage) -> VNFeaturePrintObservation? {
    let cropped = ConsistencyMetric.cropToSubject(image) ?? image
    return try? ConsistencyMetric.featurePrint(of: cropped)
  }
  static func main() {
    let root = ("~/Library/Application Support/Mimo/Pets" as NSString).expandingTildeInPath
    let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    var perPet: [[VNFeaturePrintObservation]] = []
    var names: [String] = []
    for dir in dirs {
      let sheet = "\(root)/\(dir)/sheet.png"
      guard FileManager.default.fileExists(atPath: sheet), let image = load(sheet) else { continue }
      let prints = cells(image).compactMap { print2($0) }
      if prints.count == 3 { perPet.append(prints); names.append(String(dir.prefix(8))) }
    }
    guard perPet.count >= 2 else { print("need at least 2 pets, found \(perPet.count)"); return }

    func d(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
      var v = Float(0); try? a.computeDistance(&v, to: b); return v
    }
    var same: [Float] = [], diff: [Float] = []
    for (i, pet) in perPet.enumerated() {
      for a in 0..<pet.count { for b in (a+1)..<pet.count { same.append(d(pet[a], pet[b])) } }
      for (j, other) in perPet.enumerated() where j > i {
        for a in pet { for b in other { diff.append(d(a, b)) } }
      }
    }
    func stats(_ xs: [Float], _ label: String) {
      let s = xs.sorted()
      print(String(format: "%@  n=%d  min=%.3f  median=%.3f  max=%.3f",
                   label, s.count, s.first ?? 0, s[s.count/2], s.last ?? 0))
    }
    print("pets: \(names.joined(separator: ", "))")
    stats(same, "SAME character (stage-to-stage) ")
    stats(diff, "DIFFERENT characters            ")

    let pairs = same.map { ConsistencyMetric.LabelledPair(distance: $0, isSameCharacter: true) }
              + diff.map { ConsistencyMetric.LabelledPair(distance: $0, isSameCharacter: false) }
    if let fit = ConsistencyMetric.calibrate(pairs) {
      print(String(format: "best threshold %.3f → accuracy %.1f%%", fit.threshold, fit.accuracy * 100))
    }
    let overlap = same.filter { s in diff.contains { $0 < s } }.count
    print("same-pairs that outrank some different-pair: \(overlap)/\(same.count)")
  }
}
