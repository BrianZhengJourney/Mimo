import Cocoa
import CryptoKit
import Foundation

private struct Dataset: Decodable {
    struct Synthetic: Decodable {
        struct ClassSpec: Decodable {
            let id: String
            let severity: String
        }
        let casesPerClass: Int
        let classes: [ClassSpec]
    }
    struct FieldJob: Decodable {
        let id: String
        let action: String
        let keepCounts: [Int]
        let severity: String
        let historicalError: String?
        let recordSHA256: String
        let batchSHA256s: [String]
    }
    struct UnknownCase: Decodable {
        let id: String
        let source: String
        let severity: String
        let reason: String
    }
    let schemaVersion: Int
    let name: String
    let providerCallCostUSD: Double
    let synthetic: Synthetic
    let fieldJobs: [FieldJob]
    let unknownCases: [UnknownCase]
}

private struct Arguments {
    let dataset: URL
    let historyRoot: URL
    let output: URL
    let label: String
    let baseline: URL?
    let commit: String

    static func parse() throws -> Arguments {
        var values: [String: String] = [:]
        var index = 1
        while index < CommandLine.arguments.count {
            let key = CommandLine.arguments[index]
            guard key.hasPrefix("--"), index + 1 < CommandLine.arguments.count else {
                throw EvalError.usage
            }
            values[key] = CommandLine.arguments[index + 1]
            index += 2
        }
        guard let dataset = values["--dataset"],
              let history = values["--history-root"],
              let output = values["--output"],
              let label = values["--label"] else { throw EvalError.usage }
        return Arguments(
            dataset: URL(fileURLWithPath: dataset),
            historyRoot: URL(fileURLWithPath: history),
            output: URL(fileURLWithPath: output),
            label: label,
            baseline: values["--baseline"].map(URL.init(fileURLWithPath:)),
            commit: values["--commit"] ?? "unknown")
    }
}

private enum EvalError: LocalizedError {
    case usage
    case invalidDataset
    case invalidFixture(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: diy_eval --dataset FILE --history-root DIR --output DIR --label NAME [--baseline FILE] [--commit SHA]"
        case .invalidDataset: return "The DIY eval dataset is invalid."
        case .invalidFixture(let detail):
            return "The fixed DIY eval fixture is missing or changed: \(detail)"
        case .invalidJSON: return "The DIY eval could not encode its report."
        }
    }
}

private struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
    mutating func signed(_ amplitude: Double) -> Double {
        (unit() * 2 - 1) * amplitude
    }
}

private struct AlphaMetrics {
    let iou: Double
    let boundaryF1: Double
    let foregroundRetention: Double
    let backgroundRejection: Double
    let score: Double
}

private struct SyntheticResult {
    let id: String
    let classID: String
    let severity: String
    let metrics: AlphaMetrics
    let passed: Bool
    let durationMS: Double
    let source: CharacterSheetRGBAImage
    let extracted: CharacterSheetRGBAImage
    let truthAlpha: [UInt8]
}

private struct FieldResult {
    let id: String
    let action: String
    let severity: String
    let historicalError: String?
    let currentError: String?
    let passed: Bool
    let durationMS: Double
    let providerCalls: Int
    let preview: CharacterSheetRGBAImage?
}

private func clampByte(_ value: Double) -> UInt8 {
    UInt8(max(0, min(255, Int(value.rounded()))))
}

private func stableSeed(_ value: String) -> UInt64 {
    value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
}

private func distanceToSegment(x: Double, y: Double,
                               ax: Double, ay: Double,
                               bx: Double, by: Double) -> Double {
    let dx = bx - ax, dy = by - ay
    let length = dx * dx + dy * dy
    guard length > 0 else { return hypot(x - ax, y - ay) }
    let t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / length))
    return hypot(x - (ax + t * dx), y - (ay + t * dy))
}

private func insideSubject(_ x: Double, _ y: Double,
                           classID: String, variant: Int) -> Bool {
    let wobble = Double((variant % 5) - 2)
    let head = pow((x - 128 - wobble) / 43, 2)
        + pow((y - 67) / 49, 2) <= 1
    let shoulders = pow((x - 128) / 63, 2)
        + pow((y - 126) / 35, 2) <= 1
    let torso = x >= 72 + wobble && x <= 184 - wobble
        && y >= 116 && y <= 207
    let leftLeg = x >= 82 && x <= 123 && y >= 196 && y <= 238
    let rightLeg = x >= 133 && x <= 174 && y >= 196 && y <= 238
    var inside = head || shoulders || torso || leftLeg || rightLeg
    if classID == "fine_hair_warm_matte" {
        inside = inside
            || distanceToSegment(x: x, y: y, ax: 91, ay: 47, bx: 48, by: 128) < 1.4
            || distanceToSegment(x: x, y: y, ax: 103, ay: 30, bx: 72, by: 118) < 1.1
            || distanceToSegment(x: x, y: y, ax: 163, ay: 35, bx: 202, by: 121) < 1.3
    }
    if classID == "green_subject_green_matte" {
        inside = inside || distanceToSegment(
            x: x, y: y, ax: 72, ay: 128, bx: 40, by: 194) < 4.5
    }
    if classID == "common_warm_matte" && variant % 4 == 0 {
        let accessory = pow((x - 218) / 15, 2) + pow((y - 135) / 18, 2) <= 1
        inside = inside || accessory
    }
    return inside
}

private func syntheticCase(classID: String, variant: Int)
    -> (source: CharacterSheetRGBAImage, truth: [UInt8]) {
    let size = 256
    let variantSeed = UInt64(variant) &* 997
    var rng = LCG(state: 0xA11FA &+ variantSeed &+ stableSeed(classID))
    var matte = (r: 241.0, g: 236.0, b: 226.0)
    if classID == "green_matte" || classID == "green_subject_green_matte" {
        matte = (0, 255, 0)
    }
    var source = CharacterSheetRGBAImage(width: size, height: size)
    var truth = [UInt8](repeating: 0, count: size * size)
    let samples = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
    for y in 0..<size {
        for x in 0..<size {
            var covered = 0
            for sample in samples where insideSubject(
                Double(x) + sample.0, Double(y) + sample.1,
                classID: classID, variant: variant) {
                covered += 1
            }
            let alpha = Double(covered) / Double(samples.count)
            truth[y * size + x] = clampByte(alpha * 255)

            var localMatte = matte
            if classID == "variable_warm_matte" {
                let wave = 4 * sin(Double(x) / 23) + 3 * cos(Double(y) / 31)
                localMatte = (matte.r + wave + rng.signed(1.5),
                              matte.g + wave + rng.signed(1.5),
                              matte.b + wave + rng.signed(1.5))
            } else {
                let noise = rng.signed(classID.contains("warm_matte") ? 1.2 : 0.4)
                localMatte = (matte.r + noise, matte.g + noise, matte.b + noise)
            }

            var foreground = (r: 52.0, g: 83.0, b: 91.0)
            if y < 112 { foreground = (42, 27, 31) }
            if classID == "light_subject_warm_matte" {
                foreground = y < 112 ? (93, 67, 58) : (229, 224, 214)
            } else if classID == "green_subject_green_matte" {
                foreground = y < 112 ? (30, 54, 38) : (24, 196, 48)
            } else if classID == "green_matte" {
                foreground = y < 112 ? (55, 33, 29) : (240, 236, 226)
            }
            let red = foreground.r * alpha + localMatte.0 * (1 - alpha)
            let green = foreground.g * alpha + localMatte.1 * (1 - alpha)
            let blue = foreground.b * alpha + localMatte.2 * (1 - alpha)
            source.setRGBA(x: x, y: y,
                           (clampByte(red), clampByte(green), clampByte(blue), 255))
        }
    }
    return (source, truth)
}

private func binaryBoundary(_ alpha: [UInt8], width: Int, height: Int) -> [Bool] {
    var result = [Bool](repeating: false, count: alpha.count)
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            let value = alpha[index] > 24
            if alpha[index] > 0 && alpha[index] < 255 {
                result[index] = true
                continue
            }
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < width && ny >= 0 && ny < height
                    && (alpha[ny * width + nx] > 24) != value {
                result[index] = true
                break
            }
        }
    }
    return result
}

private func matchedBoundaryCount(_ source: [Bool], target: [Bool],
                                  width: Int, height: Int) -> Int {
    var count = 0
    for y in 0..<height {
        for x in 0..<width where source[y * width + x] {
            var found = false
            for dy in -1...1 where !found {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny >= 0, ny < height,
                       target[ny * width + nx] {
                        found = true
                        break
                    }
                }
            }
            if found { count += 1 }
        }
    }
    return count
}

private func alphaMetrics(truth: [UInt8], predicted: [UInt8],
                          width: Int, height: Int) -> AlphaMetrics {
    var intersection = 0, union = 0
    var truthMass = 0.0, retainedMass = 0.0
    var backgroundCount = 0.0, falseBackground = 0.0
    for index in truth.indices {
        let t = truth[index], p = predicted[index]
        let tb = t > 24, pb = p > 24
        if tb && pb { intersection += 1 }
        if tb || pb { union += 1 }
        truthMass += Double(t)
        retainedMass += Double(min(t, p))
        if t == 0 {
            backgroundCount += 1
            falseBackground += Double(p) / 255
        }
    }
    let truthBoundary = binaryBoundary(truth, width: width, height: height)
    let predictedBoundary = binaryBoundary(predicted, width: width, height: height)
    let truthCount = max(1, truthBoundary.filter { $0 }.count)
    let predictedCount = max(1, predictedBoundary.filter { $0 }.count)
    let recall = Double(matchedBoundaryCount(
        truthBoundary, target: predictedBoundary, width: width, height: height))
        / Double(truthCount)
    let precision = Double(matchedBoundaryCount(
        predictedBoundary, target: truthBoundary, width: width, height: height))
        / Double(predictedCount)
    let boundaryF1 = precision + recall > 0
        ? 2 * precision * recall / (precision + recall) : 0
    let iou = union > 0 ? Double(intersection) / Double(union) : 1
    let foregroundRetention = truthMass > 0 ? retainedMass / truthMass : 1
    let backgroundRejection = backgroundCount > 0
        ? 1 - falseBackground / backgroundCount : 1
    let score = 0.40 * iou + 0.30 * boundaryF1
        + 0.20 * foregroundRetention + 0.10 * backgroundRejection
    return AlphaMetrics(iou: iou, boundaryF1: boundaryF1,
                        foregroundRetention: foregroundRetention,
                        backgroundRejection: backgroundRejection,
                        score: score)
}

private func predictedAlpha(_ image: CharacterSheetRGBAImage) -> [UInt8] {
    stride(from: 3, to: image.pixels.count, by: 4).map { image.pixels[$0] }
}

private func runSynthetic(_ dataset: Dataset) -> [SyntheticResult] {
    var results: [SyntheticResult] = []
    for spec in dataset.synthetic.classes {
        for variant in 0..<dataset.synthetic.casesPerClass {
            let fixture = syntheticCase(classID: spec.id, variant: variant)
            var extracted = fixture.source
            let started = CFAbsoluteTimeGetCurrent()
            CharacterSheetProcessor.removeBorderConnectedMatte(from: &extracted)
            let duration = (CFAbsoluteTimeGetCurrent() - started) * 1000
            let metrics = alphaMetrics(
                truth: fixture.truth, predicted: predictedAlpha(extracted),
                width: extracted.width, height: extracted.height)
            results.append(SyntheticResult(
                id: "\(spec.id)-\(String(format: "%02d", variant))",
                classID: spec.id, severity: spec.severity,
                metrics: metrics, passed: metrics.score >= 0.90,
                durationMS: duration, source: fixture.source,
                extracted: extracted, truthAlpha: fixture.truth))
        }
    }
    return results
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func validateFixtures(_ dataset: Dataset, arguments: Arguments) throws {
    let jobsRoot = arguments.historyRoot.appendingPathComponent("StarterActionJobs")
    guard Set(dataset.fieldJobs.map(\.id)).count == dataset.fieldJobs.count else {
        throw EvalError.invalidFixture("duplicate field job id")
    }
    for item in dataset.fieldJobs {
        guard item.keepCounts.count == item.batchSHA256s.count,
              !item.keepCounts.isEmpty else {
            throw EvalError.invalidFixture("\(item.id): batch manifest mismatch")
        }
        let directory = jobsRoot.appendingPathComponent(item.id)
        let recordURL = directory.appendingPathComponent("job.json")
        guard let record = try? Data(contentsOf: recordURL),
              sha256(record) == item.recordSHA256 else {
            throw EvalError.invalidFixture("\(item.id)/job.json")
        }
        for index in item.keepCounts.indices {
            let name = String(format: "batch-%02d.png", index + 1)
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  sha256(data) == item.batchSHA256s[index] else {
                throw EvalError.invalidFixture("\(item.id)/\(name)")
            }
        }
    }
}

private func classify(_ error: Error) -> String {
    if let value = error as? ActionSheetError {
        switch value {
        case .subjectClipped(_, let edge): return "subject_clipped_\(edge)"
        case .emptyCell: return "empty_cell"
        case .cellTooSmall: return "cell_too_small"
        default: return "action_processing_invalid"
        }
    }
    if let value = error as? ActionGenerationJobError {
        switch value {
        case .invalidMetadata: return "metadata_invalid"
        case .invalidStrip: return "strip_invalid"
        default: return "result_bundle_invalid"
        }
    }
    return "unknown_processing_error"
}

private func firstFrame(_ image: CharacterSheetRGBAImage) -> CharacterSheetRGBAImage? {
    guard image.height > 0, image.width >= image.height else { return nil }
    return ActionSheetProcessor.crop(
        image, x: 0, y: 0, width: image.height, height: image.height)
}

private func runField(_ dataset: Dataset, arguments: Arguments) -> [FieldResult] {
    let fileManager = FileManager.default
    let jobsRoot = arguments.historyRoot.appendingPathComponent("StarterActionJobs")
    let validationRoot = arguments.output.appendingPathComponent("app-validation")
    try? fileManager.createDirectory(
        at: validationRoot, withIntermediateDirectories: true)
    let store = ActionGenerationJobStore(root: validationRoot)
    var results: [FieldResult] = []

    for item in dataset.fieldJobs {
        let directory = jobsRoot.appendingPathComponent(item.id)
        let recordURL = directory.appendingPathComponent("job.json")
        let started = CFAbsoluteTimeGetCurrent()
        var preview: CharacterSheetRGBAImage?
        var calls = item.keepCounts.count
        do {
            let recordData = try Data(contentsOf: recordURL)
            guard let record = try JSONSerialization.jsonObject(with: recordData)
                    as? [String: Any],
                  let characterID = record["characterID"] as? String,
                  let actionID = StarterActionID(rawValue: item.action) else {
                throw EvalError.invalidDataset
            }
            calls = record["estimatedProviderCalls"] as? Int ?? calls
            let batches = try item.keepCounts.indices.map { index in
                try Data(contentsOf: directory.appendingPathComponent(
                    String(format: "batch-%02d.png", index + 1)))
            }
            let sheet = try ActionSheetProcessor.processCoherentBatches(
                pngDatas: batches, keepCounts: item.keepCounts)
            preview = try? firstFrame(
                CharacterSheetProcessor.decodePNG(sheet.pngData))
            let definition = StarterActionCatalog.definition(actionID)
            guard sheet.frames.count == definition.finalFrameCount,
                  let anchor = sheet.frames.first else {
                throw ActionGenerationJobError.invalidStrip
            }
            let action = definition.manifestActionName
            let metadata = ActionResultBundleMetadata(
                schemaVersion: ActionResultBundleMetadata.schemaVersion,
                action: action,
                stripFilename: "action-\(action).png",
                frameCount: definition.finalFrameCount,
                cellSize: ActionSheetProcessor.outputCellSize,
                framesPerSecond: definition.previewFramesPerSecond,
                cycleDistanceCellPixels: nil,
                anchorInCell: [Double(anchor.anchorX), Double(anchor.anchorY)],
                qaFilename: "action-\(action).qa.json",
                automaticInstallAllowed: false)
            let checkerData = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "hardPass": true,
                "automaticInstallAllowed": false,
                "manualReviewRequired": true,
            ])
            _ = try store.storeGeneratedResult(
                characterID: characterID,
                sourceLabel: "Mimo DIY eval · \(item.action)",
                metadata: metadata,
                stripData: sheet.pngData,
                previewData: nil,
                checkerData: checkerData)
            let duration = (CFAbsoluteTimeGetCurrent() - started) * 1000
            results.append(FieldResult(
                id: item.id, action: item.action, severity: item.severity,
                historicalError: item.historicalError, currentError: nil,
                passed: true, durationMS: duration,
                providerCalls: calls, preview: preview))
        } catch {
            if preview == nil,
               let firstBatch = try? Data(contentsOf: directory.appendingPathComponent("batch-01.png")),
               let decoded = try? CharacterSheetProcessor.decodePNG(firstBatch) {
                let width = max(1, decoded.width / 3)
                preview = ActionSheetProcessor.crop(
                    decoded, x: 0, y: 0, width: width, height: decoded.height)
            }
            let duration = (CFAbsoluteTimeGetCurrent() - started) * 1000
            results.append(FieldResult(
                id: item.id, action: item.action, severity: item.severity,
                historicalError: item.historicalError,
                currentError: classify(error), passed: false,
                durationMS: duration, providerCalls: calls, preview: preview))
        }
    }
    return results
}

private func percentile(_ values: [Double], _ quantile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1,
                    max(0, Int(ceil(quantile * Double(sorted.count))) - 1))
    return sorted[index]
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private func rounded(_ value: Double) -> Double {
    (value * 1_000_000).rounded() / 1_000_000
}

private func resize(_ source: CharacterSheetRGBAImage, size: Int)
    -> CharacterSheetRGBAImage {
    var output = CharacterSheetRGBAImage(width: size, height: size)
    for y in 0..<size {
        let sy = min(source.height - 1, y * source.height / size)
        for x in 0..<size {
            let sx = min(source.width - 1, x * source.width / size)
            output.setRGBA(x: x, y: y, source.rgba(x: sx, y: sy))
        }
    }
    return output
}

private func extractedPreview(_ result: SyntheticResult, size: Int)
    -> CharacterSheetRGBAImage {
    let scaled = resize(result.extracted, size: size)
    var output = CharacterSheetRGBAImage(width: size, height: size)
    for y in 0..<size {
        for x in 0..<size {
            let pixel = scaled.rgba(x: x, y: y)
            let checker = ((x / 12 + y / 12) % 2 == 0) ? 220 : 175
            let alpha = Double(pixel.3) / 255
            output.setRGBA(x: x, y: y, (
                clampByte(Double(pixel.0) + Double(checker) * (1 - alpha)),
                clampByte(Double(pixel.1) + Double(checker) * (1 - alpha)),
                clampByte(Double(pixel.2) + Double(checker) * (1 - alpha)),
                255))
        }
    }
    return output
}

private func errorPreview(_ result: SyntheticResult, size: Int)
    -> CharacterSheetRGBAImage {
    let predicted = predictedAlpha(result.extracted)
    var full = CharacterSheetRGBAImage(
        width: result.extracted.width, height: result.extracted.height)
    for index in result.truthAlpha.indices {
        let delta = abs(Int(result.truthAlpha[index]) - Int(predicted[index]))
        let x = index % full.width, y = index / full.width
        full.setRGBA(x: x, y: y,
                     (UInt8(delta), UInt8(max(0, 80 - delta / 4)), 35, 255))
    }
    return resize(full, size: size)
}

private func contactSheet(_ rows: [[CharacterSheetRGBAImage]], cellSize: Int)
    throws -> Data {
    let columns = rows.map(\.count).max() ?? 1
    var sheet = CharacterSheetRGBAImage(
        width: columns * cellSize, height: max(1, rows.count) * cellSize,
        fill: (31, 26, 55, 255))
    for (row, images) in rows.enumerated() {
        for (column, raw) in images.enumerated() {
            let image = resize(raw, size: cellSize)
            for y in 0..<cellSize {
                for x in 0..<cellSize {
                    sheet.setRGBA(
                        x: column * cellSize + x, y: row * cellSize + y,
                        image.rgba(x: x, y: y))
                }
            }
        }
    }
    return try CharacterSheetProcessor.encodePNG(sheet)
}

private func jsonObject(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func dictionaryDoubles(_ value: Any?) -> [String: Double] {
    guard let raw = value as? [String: Any] else { return [:] }
    return raw.compactMapValues {
        if let value = $0 as? Double { return value }
        if let value = $0 as? NSNumber { return value.doubleValue }
        return nil
    }
}

private func compare(current: [String: Any],
                     currentCases: [[String: Any]],
                     baselineURL: URL?) -> [String: Any] {
    guard let baselineURL, let baseline = jsonObject(at: baselineURL),
          let baseMetrics = baseline["metrics"] as? [String: Any],
          let metrics = current["metrics"] as? [String: Any] else {
        return [
            "kind": "baseline",
            "allHardGatesPassed": false,
            "rolloutEligible": false,
            "reason": "A candidate comparison is required before rollout.",
        ]
    }
    func number(_ object: [String: Any], _ key: String) -> Double {
        (object[key] as? NSNumber)?.doubleValue ?? 0
    }
    let currentSuccess = number(metrics, "effectiveSuccessRate")
    let baseMatteError = number(baseMetrics, "mattePrimaryErrorRate")
    let currentMatteError = number(metrics, "mattePrimaryErrorRate")
    let matteImprovement = baseMatteError > 0
        ? 1 - currentMatteError / baseMatteError : 0
    let latencyRatio = number(baseMetrics, "p95FieldLocalLatencyMS") > 0
        ? number(metrics, "p95FieldLocalLatencyMS")
            / number(baseMetrics, "p95FieldLocalLatencyMS") : 1
    let costRatio = number(baseMetrics, "estimatedUnitCostUSD") > 0
        ? number(metrics, "estimatedUnitCostUSD") / number(baseMetrics, "estimatedUnitCostUSD") : 1

    let baseClasses = dictionaryDoubles(baseMetrics["hardClassScores"])
    let currentClasses = dictionaryDoubles(metrics["hardClassScores"])
    var resolvedDeltas: [String: Double] = [:]
    for key in Set(baseClasses.keys).union(currentClasses.keys) {
        resolvedDeltas[key] = (currentClasses[key] ?? 0) - (baseClasses[key] ?? 0)
    }
    let noClassRegression = resolvedDeltas.values.allSatisfy { $0 >= -0.02 }

    let basePareto = (baseline["errorPareto"] as? [[String: Any]]) ?? []
    let topClass = basePareto.first?["class"] as? String
    let baseTopCount = (basePareto.first?["count"] as? NSNumber)?.intValue ?? 0
    let currentPareto = (current["errorPareto"] as? [[String: Any]]) ?? []
    let currentTopCount = currentPareto.first {
        $0["class"] as? String == topClass
    }.flatMap { ($0["count"] as? NSNumber)?.intValue } ?? 0
    let topReduction = baseTopCount > 0
        ? 1 - Double(currentTopCount) / Double(baseTopCount) : 1

    let baseCaseObjects = ((baseline["cases"] as? [[String: Any]]) ?? [])
    let baseScores: [String: Double] = Dictionary(
        uniqueKeysWithValues: baseCaseObjects.compactMap {
        guard let id = $0["id"] as? String,
              let score = ($0["score"] as? NSNumber)?.doubleValue else { return nil }
        return (id, score)
    })
    let deltas: [[String: Any]] = currentCases.compactMap {
        guard let id = $0["id"] as? String,
              let score = ($0["score"] as? NSNumber)?.doubleValue,
              let base = baseScores[id] else { return nil }
        return ["id": id, "delta": rounded(score - base)]
    }
    let providerLatencyAvailable = false
    let gates: [String: Bool] = [
        "effectiveSuccessAtLeast99": currentSuccess >= 0.99,
        "topErrorReducedAtLeast50": topReduction >= 0.50,
        "matteErrorReducedAtLeast5Percent": matteImprovement >= 0.05,
        "noHardClassRegressionOver2Points": noClassRegression,
        "localP95LatencyWithin10Percent": latencyRatio <= 1.10,
        "unitCostWithin10Percent": costRatio <= 1.10,
        "providerP95LatencyAvailable": providerLatencyAvailable,
    ]
    var result: [String: Any] = [
        "kind": "candidate",
        "gates": gates,
        "classDeltas": resolvedDeltas.mapValues(rounded),
        "topErrorReduction": rounded(topReduction),
        "matteErrorRelativeReduction": rounded(matteImprovement),
        "localLatencyRatio": rounded(latencyRatio),
        "unitCostRatio": rounded(costRatio),
        "caseDeltas": deltas,
        "allHardGatesPassed": gates.values.allSatisfy { $0 },
        "rolloutEligible": gates.values.allSatisfy { $0 },
    ]
    if let topClass {
        result["baselineTopErrorClass"] = topClass
    } else {
        result["baselineTopErrorClass"] = NSNull()
    }
    return result
}

private func writeJSON(_ object: Any, to url: URL) throws {
    guard JSONSerialization.isValidJSONObject(object) else { throw EvalError.invalidJSON }
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: [.atomic])
}

@main
private struct DIYEval {
    static func main() throws {
        let arguments = try Arguments.parse()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: arguments.output, withIntermediateDirectories: true)
        let dataset = try JSONDecoder().decode(
            Dataset.self, from: Data(contentsOf: arguments.dataset))
        guard dataset.schemaVersion == 1,
              dataset.synthetic.casesPerClass > 0,
              !dataset.synthetic.classes.isEmpty,
              !dataset.fieldJobs.isEmpty else { throw EvalError.invalidDataset }
        try validateFixtures(dataset, arguments: arguments)

        let synthetic = runSynthetic(dataset)
        let field = runField(dataset, arguments: arguments)
        let syntheticSuccess = mean(synthetic.map { $0.passed ? 1 : 0 })
        let fieldSuccess = mean(field.map { $0.passed ? 1 : 0 })
        let matteScore = mean(synthetic.map(\.metrics.score))
        var classScores: [String: Double] = [:]
        for classID in Set(synthetic.map(\.classID)) {
            classScores[classID] = mean(
                synthetic.filter { $0.classID == classID }.map(\.metrics.score))
        }
        let syntheticDurations = synthetic.map(\.durationMS)
        let fieldDurations = field.map(\.durationMS)
        let unitCost = mean(field.map { Double($0.providerCalls) })
            * dataset.providerCallCostUSD

        var errors: [String: Int] = [:]
        for item in synthetic where !item.passed {
            errors["matte_\(item.classID)", default: 0] += 1
        }
        for item in field {
            if let error = item.currentError { errors[error, default: 0] += 1 }
        }
        let pareto = errors.map { ["class": $0.key, "count": $0.value] as [String: Any] }
            .sorted {
                let left = $0["count"] as? Int ?? 0
                let right = $1["count"] as? Int ?? 0
                if left == right {
                    return ($0["class"] as? String ?? "") < ($1["class"] as? String ?? "")
                }
                return left > right
            }

        let syntheticCases: [[String: Any]] = synthetic.map {
            [
                "id": $0.id,
                "source": "synthetic",
                "class": $0.classID,
                "severity": $0.severity,
                "passed": $0.passed,
                "score": rounded($0.metrics.score),
                "alphaIoU": rounded($0.metrics.iou),
                "boundaryF1": rounded($0.metrics.boundaryF1),
                "foregroundRetention": rounded($0.metrics.foregroundRetention),
                "backgroundRejection": rounded($0.metrics.backgroundRejection),
                "durationMS": rounded($0.durationMS),
            ]
        }
        let fieldCases: [[String: Any]] = field.map {
            var value: [String: Any] = [
                "id": $0.id,
                "source": "field",
                "class": $0.action,
                "severity": $0.severity,
                "passed": $0.passed,
                "score": $0.passed ? 1.0 : 0.0,
                "durationMS": rounded($0.durationMS),
                "providerCalls": $0.providerCalls,
            ]
            value["historicalError"] = $0.historicalError ?? ""
            value["currentError"] = $0.currentError ?? ""
            return value
        }
        let allCases = syntheticCases + fieldCases
        let metrics: [String: Any] = [
            "syntheticCaseCount": synthetic.count,
            "fieldCaseCount": field.count,
            "syntheticSuccessRate": rounded(syntheticSuccess),
            "fieldSuccessRate": rounded(fieldSuccess),
            "effectiveSuccessRate": rounded(min(syntheticSuccess, fieldSuccess)),
            "mattePrimaryScore": rounded(matteScore),
            "mattePrimaryErrorRate": rounded(1 - matteScore),
            "hardClassScores": classScores.mapValues(rounded),
            "p95SyntheticLatencyMS": rounded(percentile(syntheticDurations, 0.95)),
            "p95FieldLocalLatencyMS": rounded(percentile(fieldDurations, 0.95)),
            "estimatedUnitCostUSD": rounded(unitCost),
            "providerP95LatencyMS": NSNull(),
            "providerLatencyMeasured": false,
        ]
        var report: [String: Any] = [
            "schemaVersion": 1,
            "label": arguments.label,
            "dataset": dataset.name,
            "commit": arguments.commit,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "metrics": metrics,
            "errorPareto": pareto,
            "cases": allCases,
            "unknownCases": dataset.unknownCases.map {
                ["id": $0.id, "source": $0.source,
                 "severity": $0.severity, "reason": $0.reason]
            },
        ]
        let comparison = compare(
            current: report, currentCases: allCases,
            baselineURL: arguments.baseline)
        report["comparison"] = comparison

        let worst = synthetic.sorted { $0.metrics.score < $1.metrics.score }.prefix(12)
        let matteRows = worst.map {
            [resize($0.source, size: 128),
             extractedPreview($0, size: 128),
             errorPreview($0, size: 128)]
        }
        try contactSheet(matteRows, cellSize: 128).write(
            to: arguments.output.appendingPathComponent("matte-contact-sheet.png"),
            options: [.atomic])
        report["matteContactSheetRows"] = worst.map(\.id)

        let fieldRows = field.compactMap { item -> [CharacterSheetRGBAImage]? in
            guard let preview = item.preview else { return nil }
            return [preview]
        }
        try contactSheet(fieldRows, cellSize: 144).write(
            to: arguments.output.appendingPathComponent("field-contact-sheet.png"),
            options: [.atomic])
        report["fieldContactSheetRows"] = field.compactMap {
            $0.preview == nil ? nil : $0.id
        }

        if let comparisonDeltas = comparison["caseDeltas"] as? [[String: Any]] {
            let syntheticByID = Dictionary(
                uniqueKeysWithValues: synthetic.map { ($0.id, $0) })
            let fieldByID = Dictionary(
                uniqueKeysWithValues: field.map { ($0.id, $0) })
            let changed = comparisonDeltas.compactMap {
                value -> (id: String, delta: Double)? in
                guard let id = value["id"] as? String,
                      let delta = (value["delta"] as? NSNumber)?.doubleValue,
                      abs(delta) > 0.000_001 else { return nil }
                return (id, delta)
            }
            let improvements = changed.filter { $0.delta > 0 }
                .sorted { $0.delta > $1.delta }.prefix(12)
            let regressions = changed.filter { $0.delta < 0 }
                .sorted { $0.delta < $1.delta }.prefix(12)
            for (name, items, reportKey) in [
                ("improvements-contact-sheet.png", Array(improvements),
                 "improvementContactSheetRows"),
                ("regressions-contact-sheet.png", Array(regressions),
                 "regressionContactSheetRows"),
            ] {
                let rows = items.compactMap { item -> [CharacterSheetRGBAImage]? in
                    if let synthetic = syntheticByID[item.id] {
                        return [
                            resize(synthetic.source, size: 128),
                            extractedPreview(synthetic, size: 128),
                            errorPreview(synthetic, size: 128),
                        ]
                    }
                    if let preview = fieldByID[item.id]?.preview {
                        return [preview]
                    }
                    return nil
                }
                try contactSheet(rows, cellSize: 128).write(
                    to: arguments.output.appendingPathComponent(name),
                    options: [.atomic])
                report[reportKey] = items.map(\.id)
            }
        }

        try writeJSON(allCases, to: arguments.output.appendingPathComponent("cases.json"))
        try writeJSON(report, to: arguments.output.appendingPathComponent("metrics.json"))

        print(String(format: "effective success %.1f%% · matte %.3f · field %.1f%% · field p95 %.1fms",
                     min(syntheticSuccess, fieldSuccess) * 100,
                     matteScore, fieldSuccess * 100,
                     percentile(fieldDurations, 0.95)))
        if let first = pareto.first {
            print("Pareto #1: \(first["class"] ?? "none") × \(first["count"] ?? 0)")
        } else {
            print("Pareto #1: none")
        }
    }
}
