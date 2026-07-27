// sources: consistency_metric.swift
import CoreGraphics
import Foundation
import Vision

@main
struct ConsistencyMetricTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    /// A cell with one opaque rect, drawn in a given colour.
    static func cell(size: Int = 96, blob: CGRect, gray: CGFloat = 0.2) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: gray, green: gray * 0.5, blue: 1 - gray, alpha: 1))
        context.fill(CGRect(x: blob.minX, y: CGFloat(size) - blob.maxY,
                            width: blob.width, height: blob.height))
        return context.makeImage()!
    }

    static func reading(_ index: Int, _ distance: Float,
                        height: CGFloat = 40, coverage: Double = 0.3) -> ConsistencyReading {
        ConsistencyReading(index: index, distance: distance,
                           subjectHeight: height, coverage: coverage)
    }

    // MARK: - Subject bounds

    static func testSubjectBoundsFindTheArt() {
        let image = cell(blob: CGRect(x: 20, y: 10, width: 30, height: 40))
        guard let bounds = ConsistencyMetric.subjectBounds(of: image) else {
            preconditionFailure("bounds should be found")
        }
        expect(abs(bounds.minX - 20) <= 1, "left edge")
        expect(abs(bounds.width - 30) <= 2, "width")
        expect(abs(bounds.height - 40) <= 2, "height")
    }

    static func testEmptyCellHasNoBounds() {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        expect(ConsistencyMetric.subjectBounds(of: context.makeImage()!) == nil,
               "a fully transparent cell has no subject")
    }

    // MARK: - Vision plumbing

    /// The revision must be pinned. Vision's model has changed across OS
    /// releases, and a threshold calibrated against one revision does not mean
    /// the same thing against the next — an OS update would silently re-scale
    /// the gate.
    static func testRevisionIsPinned() {
        expect(ConsistencyMetric.visionRevision == VNGenerateImageFeaturePrintRequestRevision1,
               "the feature print revision must be explicitly pinned, not left to default")
    }

    static func testIdenticalImagesAreMaximallySimilar() throws {
        let image = cell(blob: CGRect(x: 20, y: 20, width: 40, height: 50))
        let distance = try ConsistencyMetric.distance(
            ConsistencyMetric.featurePrint(of: image),
            ConsistencyMetric.featurePrint(of: image))
        expect(distance < 0.001, "an image against itself should be ~0, got \(distance)")
    }

    /// The property the whole gate rests on: a different-looking cell must
    /// score further from the reference than a similar one. If this ordering
    /// does not hold, no threshold can work.
    static func testDifferentSubjectsScoreFurtherThanSimilarOnes() throws {
        let reference = cell(blob: CGRect(x: 30, y: 20, width: 36, height: 56), gray: 0.2)
        let similar = cell(blob: CGRect(x: 31, y: 21, width: 36, height: 55), gray: 0.22)
        let different = cell(blob: CGRect(x: 4, y: 60, width: 88, height: 12), gray: 0.9)

        let referencePrint = try ConsistencyMetric.featurePrint(of: reference)
        let near = try ConsistencyMetric.distance(
            ConsistencyMetric.featurePrint(of: similar), referencePrint)
        let far = try ConsistencyMetric.distance(
            ConsistencyMetric.featurePrint(of: different), referencePrint)
        expect(far > near,
               "a visibly different cell must score further away (near \(near), far \(far))")
    }

    static func testEvaluateScoresEveryCell() throws {
        let reference = cell(blob: CGRect(x: 30, y: 20, width: 36, height: 56))
        let cells = [
            cell(blob: CGRect(x: 30, y: 20, width: 36, height: 56)),
            cell(blob: CGRect(x: 31, y: 21, width: 35, height: 55)),
            cell(blob: CGRect(x: 29, y: 19, width: 37, height: 57)),
        ]
        let report = try ConsistencyMetric.evaluate(cells: cells, reference: reference)
        expect(report.readings.count == 3, "one reading per cell")
        expect(report.readings.map(\.index) == [0, 1, 2], "readings keep cell order")
        expect(report.readings.allSatisfy { $0.coverage > 0 }, "every cell has coverage")
        expect(!report.summary.isEmpty, "a summary line exists for the run log")
    }

    static func testEmptySheetIsRerolled() throws {
        let reference = cell(blob: CGRect(x: 10, y: 10, width: 20, height: 20))
        let report = try ConsistencyMetric.evaluate(cells: [], reference: reference)
        guard case .rerollSheet = report.verdict else {
            preconditionFailure("a sheet with no cells must be rerolled, got \(report.verdict)")
        }
    }

    // MARK: - Grading policy

    /// Distances are on the measured scale (roughly 5–29), not 0–1. An earlier
    /// draft guessed 0.55/0.9 and would have rejected every sheet ever made.
    static func testAllCloseCellsPass() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.1), reading(1, 6.0), reading(2, 5.6)],
            thresholds: .measured)
        expect(verdict == .pass, "cells clustered near the reference should pass, got \(verdict)")
    }

    /// One drifted cell is repairable, which is what the existing single-stage
    /// regeneration path already does.
    static func testOneDriftedCellIsRepairedNotRerolled() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.2), reading(1, 10.4), reading(2, 5.6)],
            thresholds: ConsistencyThresholds(pass: 9.0, fail: 13.0,
                                              spread: 99, scaleVariation: 99))
        expect(verdict == .repairCells([1]), "only the drifted cell needs repair, got \(verdict)")
    }

    /// A cell past the fail line usually means the sampling went wide, and
    /// patching one cell will not bring the sheet back.
    static func testAWildCellRerollsTheSheet() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.2), reading(1, 19.4), reading(2, 5.6)],
            thresholds: .measured)
        guard case .rerollSheet(let reason) = verdict else {
            preconditionFailure("expected a reroll, got \(verdict)")
        }
        expect(reason.contains("cell 1"), "the reason names the offending cell: \(reason)")
    }

    /// The check per-cell scoring cannot make. Every cell is individually
    /// within tolerance but they disagree with each other, which is what a
    /// sheet that drifted as a whole looks like.
    static func testASheetThatDriftedTogetherIsCaught() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.0), reading(1, 11.5), reading(2, 5.0)],
            thresholds: ConsistencyThresholds(pass: 12.0, fail: 13.0,
                                              spread: 2.0, scaleVariation: 99))
        guard case .rerollSheet(let reason) = verdict else {
            preconditionFailure("expected a reroll on spread, got \(verdict)")
        }
        expect(reason.contains("spread"), "the reason names spread: \(reason)")
    }

    static func testScaleJumpIsCaught() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.0, height: 40), reading(1, 5.0, height: 80),
                  reading(2, 5.0, height: 40)],
            thresholds: .measured)
        guard case .rerollSheet(let reason) = verdict else {
            preconditionFailure("expected a reroll on scale, got \(verdict)")
        }
        expect(reason.contains("size"), "the reason names the size change: \(reason)")
    }

    static func testIntentionalPoseHeightChangeIsNotScaleDrift() {
        let readings = [
            reading(0, 5.0, height: 80), reading(1, 5.0, height: 82),
            reading(2, 5.0, height: 42), reading(3, 5.0, height: 40),
        ]
        let verdict = ConsistencyMetric.verdict(
            for: readings,
            thresholds: .measured,
            scaleGroups: [[0, 1], [2, 3]])
        expect(verdict == .pass,
               "standing and lying groups may differ in height without becoming scale drift, got \(verdict)")
    }

    static func testScaleJumpWithinComparablePoseGroupIsCaught() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.0, height: 80), reading(1, 5.0, height: 48),
                  reading(2, 5.0, height: 42), reading(3, 5.0, height: 40)],
            thresholds: .measured,
            scaleGroups: [[0, 1], [2, 3]])
        guard case .rerollSheet(let reason) = verdict else {
            preconditionFailure("expected comparable-pose scale reroll, got \(verdict)")
        }
        expect(reason.contains("[0,1]"), "the reason identifies the bad comparable group: \(reason)")
    }

    static func testEmptyCellIsCaughtBeforeDistance() {
        let verdict = ConsistencyMetric.verdict(
            for: [reading(0, 5.0), reading(1, 5.0, coverage: 0)],
            thresholds: .measured)
        guard case .rerollSheet(let reason) = verdict else {
            preconditionFailure("expected a reroll on an empty cell, got \(verdict)")
        }
        expect(reason.contains("empty"), "the reason names emptiness: \(reason)")
    }

    /// Pins the thresholds to the scale that was actually measured, so nobody
    /// re-introduces 0-to-1 numbers that would reject every sheet.
    static func testThresholdsAreOnTheMeasuredScale() {
        let t = ConsistencyThresholds.measured
        expect(t.pass > 7.9, "pass must clear the observed within-sheet maximum of 7.90")
        expect(t.pass < 11.1, "pass must sit below the observed cross-character minimum of 11.14")
        expect(t.fail > t.pass, "the reroll line must sit above the repair line")
        expect(t.fail < 18.4, "reroll must trigger below the cross-character median")
    }

    // MARK: - Calibration

    /// Thresholds are fitted, never inherited. Every published number for this
    /// kind of metric was fitted by its author to their own data.
    static func testCalibrationSeparatesLabelledPairs() {
        let pairs = [
            ConsistencyMetric.LabelledPair(distance: 0.10, isSameCharacter: true),
            ConsistencyMetric.LabelledPair(distance: 0.15, isSameCharacter: true),
            ConsistencyMetric.LabelledPair(distance: 0.20, isSameCharacter: true),
            ConsistencyMetric.LabelledPair(distance: 0.70, isSameCharacter: false),
            ConsistencyMetric.LabelledPair(distance: 0.80, isSameCharacter: false),
        ]
        guard let fitted = ConsistencyMetric.calibrate(pairs) else {
            preconditionFailure("calibration should succeed on separable data")
        }
        expect(fitted.accuracy == 1.0, "cleanly separable data should fit perfectly")
        expect(fitted.threshold >= 0.20 && fitted.threshold < 0.70,
               "the boundary should land between the groups, got \(fitted.threshold)")
    }

    /// The number that actually matters. If the best achievable accuracy is
    /// poor, the metric cannot see this kind of drift and no threshold will
    /// fix it — that is the signal to bundle a DINOv2 instead of shipping a
    /// gate that cannot do its job.
    static func testCalibrationReportsPoorSeparation() {
        let pairs = (0..<10).map { index in
            ConsistencyMetric.LabelledPair(distance: 0.5, isSameCharacter: index % 2 == 0)
        }
        guard let fitted = ConsistencyMetric.calibrate(pairs) else {
            preconditionFailure("calibration should still return something")
        }
        expect(fitted.accuracy < 0.75,
               "indistinguishable data must not report high accuracy, got \(fitted.accuracy)")
    }

    static func testCalibrationNeedsBothLabels() {
        let onlySame = [
            ConsistencyMetric.LabelledPair(distance: 0.1, isSameCharacter: true),
            ConsistencyMetric.LabelledPair(distance: 0.2, isSameCharacter: true),
        ]
        expect(ConsistencyMetric.calibrate(onlySame) == nil,
               "one-sided labels cannot fit a boundary")
        expect(ConsistencyMetric.calibrate([]) == nil, "no data cannot fit a boundary")
    }

    static func main() throws {
        testSubjectBoundsFindTheArt()
        testEmptyCellHasNoBounds()
        testRevisionIsPinned()
        do {
            try testIdenticalImagesAreMaximallySimilar()
            try testDifferentSubjectsScoreFurtherThanSimilarOnes()
            try testEvaluateScoresEveryCell()
        } catch {
            let failure = error as NSError
            guard failure.domain == "com.apple.Vision", failure.code == 9 else { throw error }
            print("consistency metric: Vision feature-print checks skipped (system ANE model unavailable)")
        }
        try testEmptySheetIsRerolled()
        testAllCloseCellsPass()
        testOneDriftedCellIsRepairedNotRerolled()
        testAWildCellRerollsTheSheet()
        testASheetThatDriftedTogetherIsCaught()
        testScaleJumpIsCaught()
        testIntentionalPoseHeightChangeIsNotScaleDrift()
        testScaleJumpWithinComparablePoseGroupIsCaught()
        testEmptyCellIsCaughtBeforeDistance()
        testThresholdsAreOnTheMeasuredScale()
        testCalibrationSeparatesLabelledPairs()
        testCalibrationReportsPoorSeparation()
        testCalibrationNeedsBothLabels()
        print("consistency metric: all assertions passed")
    }
}
