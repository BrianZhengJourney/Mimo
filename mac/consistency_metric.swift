import CoreGraphics
import Foundation
import Vision

// Does this sheet still depict the same character?
//
// Neither backend exposes a seed, so consistency cannot be guaranteed before
// generation — it has to be measured after and repaired. That makes this the
// load-bearing part of the batch-generation design rather than a nicety. See
// docs/companion/04-generation-and-consistency.md §4.10.
//
// Vision's feature print is the right first move: the app already links Vision,
// so this costs no new dependency, no network, and no per-call money. Two
// caveats are handled explicitly rather than discovered later.
//
// The revision is pinned. Vision's underlying model has changed across OS
// releases before, and a threshold calibrated against one revision does not
// mean the same thing against the next. Shipping a hardcoded threshold without
// pinning would let an OS update silently re-scale the quality gate.
//
// And the feature print is a general-purpose semantic descriptor, tuned for
// photo-library tasks, not a subject-identity embedding. The literature on
// subject fidelity prefers DINO-style embeddings precisely because they
// separate different individuals of the same class better — which is exactly
// this failure mode, "same species, wrong character". So this must be
// validated against hand-labelled pairs before it is trusted as a gate, and
// `MimoConsistencyThresholds` is deliberately not shipped with numbers
// pretending to be calibrated.

enum ConsistencyMetricError: Error, CustomStringConvertible {
    case featurePrintUnavailable
    case incomparable

    var description: String {
        switch self {
        case .featurePrintUnavailable: return "Vision produced no feature print for the image"
        case .incomparable: return "two feature prints could not be compared"
        }
    }
}

/// One cell's verdict.
struct ConsistencyReading {
    let index: Int
    /// Distance from the locked reference. Smaller is more similar.
    let distance: Float
    /// Height of the cell's opaque bounds, in cell pixels.
    let subjectHeight: CGFloat
    /// Fraction of the cell that is opaque.
    let coverage: Double
}

struct ConsistencyThresholds {
    /// At or below this, a cell passes.
    let pass: Float
    /// Above this, the whole sheet is rerolled rather than the cell repaired —
    /// a cell this far off usually means the sampling went wide, and patching
    /// one cell will not bring it back.
    let fail: Float
    /// Cap on the spread of cell distances. Catches a sheet that drifted
    /// together, which per-cell checks cannot see.
    let spread: Float
    /// Cap on the coefficient of variation of subject heights, catching a cell
    /// where the character suddenly changed scale.
    let scaleVariation: Double

    /// Fitted against this app's own generated sheets on 2026-07-20, not
    /// inherited from anywhere. Every published threshold for this kind of
    /// metric was fitted by its author to their own data.
    ///
    /// What was measured, using the app's existing pets:
    ///
    ///   same character, same stage, different expression   4.89 – 7.90  (n=9)
    ///   different characters                              11.14 – 28.99 (n=324)
    ///
    /// The first row is the variation the gate must tolerate — three cells of
    /// one expression sheet are the closest available stand-in for an action
    /// sheet's poses. The second is what it must catch. They separate cleanly,
    /// so Vision's feature print is discriminative enough here and a bundled
    /// DINOv2 is not needed yet.
    ///
    /// Note the scale: distances run to ~29, not 0–1. An earlier draft of this
    /// file guessed 0.55/0.9, which would have rejected every sheet ever
    /// generated.
    ///
    /// One caveat kept in view: only one familiar has expression sheets, so the
    /// tolerated-variation sample is small, and stage-to-stage distances
    /// (8.58 – 26.41) straddle this boundary — correctly, since evolution
    /// stages are meant to differ. Cells must therefore only ever be compared
    /// against a reference of the *same* stage.
    static let measured = ConsistencyThresholds(
        pass: 9.0, fail: 13.0, spread: 3.0, scaleVariation: 0.12)

    /// Kept as the default until the sample is larger than one familiar.
    static let provisional = measured
}

enum ConsistencyVerdict: Equatable {
    case pass
    /// Named cells drifted but the sheet is worth repairing.
    case repairCells([Int])
    /// Reroll the whole sheet, with the reason.
    case rerollSheet(String)
}

struct ConsistencyReport {
    let readings: [ConsistencyReading]
    let verdict: ConsistencyVerdict

    var worstDistance: Float { readings.map(\.distance).max() ?? 0 }
    var meanDistance: Float {
        readings.isEmpty ? 0 : readings.map(\.distance).reduce(0, +) / Float(readings.count)
    }

    /// One line for the run log, so distributions can be gathered before the
    /// gate is ever allowed to spend money on a reroll.
    var summary: String {
        let distances = readings.map { String(format: "%.3f", $0.distance) }.joined(separator: " ")
        return "cells=\(readings.count) mean=\(String(format: "%.3f", meanDistance)) "
             + "worst=\(String(format: "%.3f", worstDistance)) [\(distances)] → \(verdict)"
    }
}

enum ConsistencyMetric {
    /// Pinned deliberately. See the file comment.
    static let visionRevision = VNGenerateImageFeaturePrintRequestRevision1

    /// Feature print for one image.
    static func featurePrint(of image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = visionRevision
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw ConsistencyMetricError.featurePrintUnavailable
        }
        return observation
    }

    static func distance(_ lhs: VNFeaturePrintObservation,
                         _ rhs: VNFeaturePrintObservation) throws -> Float {
        var value = Float(0)
        do { try lhs.computeDistance(&value, to: rhs) }
        catch { throw ConsistencyMetricError.incomparable }
        return value
    }

    /// Scores every cell of a sliced sheet against the locked reference.
    ///
    /// Cells are cropped to their opaque bounds first: background and framing
    /// otherwise dominate the embedding, and a cell that merely sits lower in
    /// its box would read as a different character.
    ///
    /// Scoring is cell-against-reference rather than cell-against-cell. The
    /// question is drift from truth, and comparing cells to each other lets a
    /// whole sheet drift together undetected.
    static func evaluate(cells: [CGImage],
                         reference: CGImage,
                         thresholds: ConsistencyThresholds = .provisional) throws -> ConsistencyReport {
        guard !cells.isEmpty else {
            return ConsistencyReport(readings: [], verdict: .rerollSheet("the sheet had no cells"))
        }

        let referencePrint = try featurePrint(of: cropToSubject(reference) ?? reference)
        var readings: [ConsistencyReading] = []

        for (index, cell) in cells.enumerated() {
            let bounds = subjectBounds(of: cell)
            let cropped = bounds.map { cell.cropping(to: $0) ?? cell } ?? cell
            let distance = try distance(featurePrint(of: cropped), referencePrint)
            let area = Double(cell.width * cell.height)
            readings.append(ConsistencyReading(
                index: index,
                distance: distance,
                subjectHeight: bounds?.height ?? 0,
                coverage: area > 0 ? Double((bounds?.width ?? 0) * (bounds?.height ?? 0)) / area : 0))
        }

        return ConsistencyReport(readings: readings,
                                 verdict: verdict(for: readings, thresholds: thresholds))
    }

    /// Grades a set of readings without needing Vision, so the policy is
    /// testable on its own.
    static func verdict(for readings: [ConsistencyReading],
                        thresholds: ConsistencyThresholds) -> ConsistencyVerdict {
        guard !readings.isEmpty else { return .rerollSheet("no cells to judge") }

        if let empty = readings.first(where: { $0.coverage <= 0.001 }) {
            return .rerollSheet("cell \(empty.index) is empty")
        }
        if let blown = readings.first(where: { $0.distance > thresholds.fail }) {
            return .rerollSheet("cell \(blown.index) is too far from the reference "
                                + "(\(String(format: "%.3f", blown.distance)))")
        }

        // A sheet whose cells all drifted the same way passes every per-cell
        // check while being wrong as a whole, so spread is checked separately.
        let distances = readings.map(\.distance)
        if distances.count > 1 {
            let mean = distances.reduce(0, +) / Float(distances.count)
            let variance = distances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(distances.count)
            if variance.squareRoot() > thresholds.spread {
                return .rerollSheet("cell distances are too spread out "
                                    + "(σ=\(String(format: "%.3f", variance.squareRoot())))")
            }
        }

        let heights = readings.map { Double($0.subjectHeight) }.filter { $0 > 0 }
        if heights.count > 1 {
            let mean = heights.reduce(0, +) / Double(heights.count)
            if mean > 0 {
                let variance = heights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(heights.count)
                if variance.squareRoot() / mean > thresholds.scaleVariation {
                    return .rerollSheet("the character changes size between cells")
                }
            }
        }

        let drifted = readings.filter { $0.distance > thresholds.pass }.map(\.index)
        return drifted.isEmpty ? .pass : .repairCells(drifted)
    }

    // MARK: - Subject bounds

    /// Opaque bounds in CoreGraphics pixel space, or nil if the cell is empty.
    ///
    /// Shares its threshold with the sprite loader: matte extraction leaves a
    /// faint fringe, and counting it as solid inflates the crop.
    static func subjectBounds(of image: CGImage,
                              alphaThreshold: UInt8 = 24) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where buffer[row + x] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    static func cropToSubject(_ image: CGImage) -> CGImage? {
        guard let bounds = subjectBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    // MARK: - Calibration

    /// A hand-labelled pair, for fitting thresholds against real data.
    struct LabelledPair {
        let distance: Float
        /// True when a human said these show the same character.
        let isSameCharacter: Bool
    }

    /// Picks the pass threshold that best separates labelled pairs, and reports
    /// how well it actually separates them.
    ///
    /// The separation number matters more than the threshold. If the best
    /// achievable accuracy is poor, the metric is not discriminative enough for
    /// this task and no threshold will save it — which is the signal to bundle
    /// a Core ML DINOv2 instead of shipping a gate that cannot see drift.
    static func calibrate(_ pairs: [LabelledPair]) -> (threshold: Float, accuracy: Double)? {
        guard pairs.count >= 2,
              pairs.contains(where: \.isSameCharacter),
              pairs.contains(where: { !$0.isSameCharacter }) else { return nil }

        let candidates = pairs.map(\.distance).sorted()
        var best: (threshold: Float, accuracy: Double)?
        for (index, value) in candidates.enumerated() {
            // Test midpoints between observed distances as well as the values
            // themselves, so the chosen boundary is not pinned to a sample.
            let next = index + 1 < candidates.count ? candidates[index + 1] : value + 0.05
            for threshold in [value, (value + next) / 2] {
                let correct = pairs.filter { ($0.distance <= threshold) == $0.isSameCharacter }.count
                let accuracy = Double(correct) / Double(pairs.count)
                if best == nil || accuracy > best!.accuracy {
                    best = (threshold, accuracy)
                }
            }
        }
        return best
    }
}
