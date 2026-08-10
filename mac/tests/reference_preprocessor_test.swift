// sources: reference_preprocessor.swift
import AppKit
import Foundation
import ImageIO

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func png(width: Int = 400, height: Int = 500,
                 color: (UInt8, UInt8, UInt8) = (180, 50, 45),
                 darkBands: Bool = false) -> Data {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let dark = darkBands && (y < height / 5 || y >= height * 4 / 5)
            let offset = (y * width + x) * 4
            pixels[offset] = dark ? 0 : color.0
            pixels[offset + 1] = dark ? 0 : color.1
            pixels[offset + 2] = dark ? 0 : color.2
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                        bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

private func whiteMask() -> CGImage {
    let provider = CGDataProvider(data: Data([255]) as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

private final class ScalarIdentityFeature: MimoReferenceIdentityFeature {
    let value: Float
    init(_ value: Float) { self.value = value }

    override func distance(to other: MimoReferenceIdentityFeature) -> Float? {
        guard let other = other as? ScalarIdentityFeature else { return nil }
        return abs(value - other.value)
    }
}

private final class StubAnalyzer: MimoReferenceVisionAnalyzing {
    var analyses: [MimoReferenceRawAnalysis]
    var featureValues: [Float?]
    var analysisCallCount = 0
    var analysisErrorsRemaining = 0
    var maskAvailable = true

    init(analyses: [MimoReferenceRawAnalysis], featureValues: [Float?] = []) {
        self.analyses = analyses
        self.featureValues = featureValues
    }

    func analyze(_ image: CGImage) throws -> MimoReferenceRawAnalysis {
        analysisCallCount += 1
        if analysisErrorsRemaining > 0 {
            analysisErrorsRemaining -= 1
            throw StubError.analysis
        }
        guard !analyses.isEmpty else {
            return MimoReferenceRawAnalysis(people: [], faces: [], textRegions: [],
                                            usedCollagePasses: false)
        }
        return analyses.removeFirst()
    }

    func personMask(for portrait: CGImage) throws -> CGImage? {
        maskAvailable ? whiteMask() : nil
    }

    func identityFeature(for faceCrop: CGImage) throws -> MimoReferenceIdentityFeature? {
        guard !featureValues.isEmpty else { return nil }
        guard let value = featureValues.removeFirst() else { return nil }
        return ScalarIdentityFeature(value)
    }
}

private enum StubError: Error { case analysis }

private func person(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                    confidence: Float = 0.92,
                    coverage: MimoReferenceCoverage = .fullBody,
                    source: MimoReferenceDetectionSource = .fullFrame)
    -> MimoReferenceRawPersonObservation {
    MimoReferenceRawPersonObservation(
        bounds: CGRect(x: x, y: y, width: width, height: height),
        confidence: confidence, coverage: coverage, source: source)
}

private func face(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                  confidence: Float = 0.95, yaw: Float = 0)
    -> MimoReferenceRawFaceObservation {
    MimoReferenceRawFaceObservation(
        bounds: CGRect(x: x, y: y, width: width, height: height),
        confidence: confidence, yawRadians: yaw)
}

private func analysis(people: [MimoReferenceRawPersonObservation] = [],
                      faces: [MimoReferenceRawFaceObservation] = [],
                      text: [CGRect] = [], collage: Bool = false)
    -> MimoReferenceRawAnalysis {
    MimoReferenceRawAnalysis(people: people, faces: faces,
                             textRegions: text, usedCollagePasses: collage)
}

private func containsApproximateColor(_ data: Data,
                                      red: Int, green: Int, blue: Int,
                                      tolerance: Int = 5) -> Bool {
    guard let bitmap = NSBitmapImageRep(data: data) else { return false }
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let actual = [Int(color.redComponent * 255),
                          Int(color.greenComponent * 255),
                          Int(color.blueComponent * 255)]
            if abs(actual[0] - red) <= tolerance && abs(actual[1] - green) <= tolerance &&
                abs(actual[2] - blue) <= tolerance { return true }
        }
    }
    return false
}

@main
struct ReferencePreprocessorTests {
    static func main() {
        let source = png()
        let richAnalysis = analysis(
            people: [
                person(0.15, 0.08, 0.48, 0.78, source: .collageTile),
                person(0.72, 0.56, 0.12, 0.23, confidence: 0.55,
                       coverage: .upperBody, source: .collageTile),
            ],
            faces: [
                face(0.27, 0.65, 0.17, 0.16, yaw: 0.82),
                face(0.75, 0.70, 0.07, 0.07, confidence: 0.70),
            ],
            text: [CGRect(x: 0.30, y: 0.37, width: 0.21, height: 0.08)],
            collage: true)
        let richStub = StubAnalyzer(analyses: [richAnalysis], featureValues: [0, 35])
        let rich = MimoReferencePreprocessor(analyzer: richStub).process([
            MimoReferenceInput(id: "social-shot", data: source),
        ])
        expect(rich.hasUsablePerson, "a person inside a noisy collage should remain usable")
        expect(rich.images[0].detectedPersonCount == 2,
               "all plausible people should be visible as evidence")
        expect(rich.images[0].warnings.contains(.collagePanelsScanned),
               "collage scanning should be disclosed")
        expect(rich.images[0].warnings.contains(.textOverlayDetected),
               "text detection should be disclosed without retaining OCR strings")
        expect(rich.recommendedReferences.count == 1,
               "an identity-incompatible second person must not enter the board")
        let primary = rich.recommendedReferences[0]
        expect(primary.view == .profile, "face yaw should preserve angle evidence")
        expect(abs(primary.normalizedPersonBounds.y - 0.14) < 0.001,
               "public rectangles should use a top-left origin")
        expect(primary.backgroundRemoved, "a successful person mask should be reported")
        expect(primary.warnings.contains(.textOverlayRemoved),
               "intersecting OCR regions should be removed from the clean crop")
        expect(containsApproximateColor(primary.portraitPNG, red: 195, green: 70, blue: 58,
                                        tolerance: 18),
               "cleaned portraits should retain non-text subject pixels")
        expect(!containsApproximateColor(primary.portraitPNG, red: 241, green: 236, blue: 226,
                                         tolerance: 4),
               "OCR cleanup must blur subject pixels rather than cut parchment-colored holes")
        expect(rich.providerPayload?.identityBoard.mode == .isolatedPeople,
               "person evidence should produce an isolated-person board")
        expect(rich.providerPayload?.identityBoard.pixelSize ==
               MimoReferencePixelSize(width: 1024, height: 1024),
               "the provider board contract must remain 1024 by 1024")
        if let json = rich.providerPayload?.analysisJSON,
           let jsonData = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            expect(object["schema"] as? String == "mimo.reference-evidence.v1",
                   "provider metadata needs a versioned schema")
            expect(!json.contains("social-shot"),
                   "provider JSON should not contain user input IDs or filenames")
            let refs = object["references"] as? [[String: Any]] ?? []
            expect(refs.first?["role"] as? String == "primary_anchor"
                   && refs.dropFirst().allSatisfy { $0["role"] as? String == "supporting" },
                   "slot 1 must be marked as the primary identity anchor")
            expect(json.contains("primary identity anchor"),
                   "instructions must subordinate supporting slots to the anchor")
        } else {
            expect(false, "provider analysis JSON should be valid")
        }

        // Same-person grouping: select a lower-ranked but matching face from a
        // second collage, and reject a clearly different third upload.
        let twoPeople = analysis(
            people: [person(0.08, 0.08, 0.46, 0.82),
                     person(0.57, 0.20, 0.33, 0.65, confidence: 0.74)],
            faces: [face(0.19, 0.66, 0.16, 0.15),
                    face(0.65, 0.68, 0.14, 0.14, confidence: 0.84, yaw: 0.85)],
            collage: true)
        let groupingStub = StubAnalyzer(
            analyses: [twoPeople, twoPeople,
                       analysis(people: [person(0.2, 0.1, 0.55, 0.8)],
                                faces: [face(0.35, 0.66, 0.18, 0.16)])],
            featureValues: [0, 35, 34, 2, 40])
        let grouped = MimoReferencePreprocessor(analyzer: groupingStub).process([
            MimoReferenceInput(id: "primary", data: source),
            MimoReferenceInput(id: "second", data: source),
            MimoReferenceInput(id: "different", data: source),
        ])
        expect(grouped.recommendedReferences.contains(where: {
            $0.sourceInputID == "second" && $0.id.hasSuffix("person:1")
        }), "the nearest identity feature should win inside a secondary collage")
        expect(!grouped.recommendedReferences.contains(where: {
            $0.sourceInputID == "different"
        }), "an unambiguously distant face should be excluded")

        // A single collage can contribute two useful angles, but only with
        // positive identity compatibility.
        let compatibleStub = StubAnalyzer(analyses: [twoPeople], featureValues: [0, 3])
        let compatible = MimoReferencePreprocessor(analyzer: compatibleStub).process([
            MimoReferenceInput(id: "two-angles", data: source),
        ])
        expect(compatible.recommendedReferences.count == 2,
               "compatible alternate collage angles should both be retained")

        let ambiguousStub = StubAnalyzer(analyses: [twoPeople], featureValues: [nil, nil])
        let ambiguous = MimoReferencePreprocessor(analyzer: ambiguousStub).process([
            MimoReferenceInput(id: "ambiguous", data: source),
        ])
        expect(ambiguous.recommendedReferences.count == 1,
               "without identity evidence a collage should contribute only its dominant person")
        expect(ambiguous.images[0].warnings.contains(.identityAmbiguous),
               "missing identity evidence should be explicit")

        // Once several clean uploads already establish the subject, noisy
        // screenshots must not fill the remaining board cells merely because
        // the board has spare capacity. This reproduces the real five-image
        // failure: a phone-obscured alternate and a high-confidence video/UI
        // frame displaced cleaner identity angles.
        let cleanProfile = analysis(
            people: [person(0.12, 0.08, 0.52, 0.82)],
            faces: [face(0.24, 0.66, 0.17, 0.15, confidence: 0.78, yaw: 0.86)])
        let cleanPlusPhoneAlternate = analysis(
            people: [person(0.05, 0.08, 0.42, 0.82),
                     person(0.58, 0.15, 0.34, 0.68, confidence: 0.78)],
            faces: [face(0.16, 0.66, 0.16, 0.15, confidence: 0.94, yaw: 0.42),
                    face(0.66, 0.66, 0.14, 0.13, confidence: 0.70, yaw: 0.42)],
            collage: true)
        let uiHeavy = analysis(
            people: [person(0.04, 0.07, 0.88, 0.86, confidence: 0.98)],
            faces: [face(0.34, 0.67, 0.18, 0.16, confidence: 0.96, yaw: 0.02)],
            text: [
                CGRect(x: 0.08, y: 0.08, width: 0.72, height: 0.08),
                CGRect(x: 0.12, y: 0.19, width: 0.68, height: 0.08),
                CGRect(x: 0.16, y: 0.30, width: 0.62, height: 0.08),
                CGRect(x: 0.20, y: 0.41, width: 0.56, height: 0.08),
                CGRect(x: 0.24, y: 0.52, width: 0.50, height: 0.08),
                CGRect(x: 0.28, y: 0.63, width: 0.44, height: 0.08),
                CGRect(x: 0.32, y: 0.74, width: 0.38, height: 0.08),
                CGRect(x: 0.36, y: 0.85, width: 0.32, height: 0.05),
                CGRect(x: 0.02, y: 0.92, width: 0.18, height: 0.04),
                CGRect(x: 0.78, y: 0.92, width: 0.18, height: 0.04),
            ], collage: true)
        let cleanFront = analysis(
            people: [person(0.18, 0.08, 0.56, 0.82)],
            faces: [face(0.36, 0.67, 0.17, 0.15, confidence: 0.95, yaw: 0.02)])
        let cleanThreeQuarter = analysis(
            people: [person(0.20, 0.10, 0.52, 0.78)],
            faces: [face(0.38, 0.66, 0.16, 0.14, confidence: 0.91, yaw: -0.44)])
        let hardenedStub = StubAnalyzer(
            analyses: [cleanProfile, cleanPlusPhoneAlternate, uiHeavy,
                       cleanFront, cleanThreeQuarter],
            featureValues: [0, 2, 3, 1, 4, 5])
        let hardened = MimoReferencePreprocessor(analyzer: hardenedStub).process([
            MimoReferenceInput(id: "clean-profile", data: source),
            MimoReferenceInput(id: "clean-plus-phone", data: source),
            MimoReferenceInput(id: "video-ui", data: source),
            MimoReferenceInput(id: "clean-front", data: source),
            MimoReferenceInput(id: "clean-three-quarter", data: source),
        ])
        expect(!hardened.recommendedReferences.contains(where: {
            $0.sourceInputID == "video-ui"
        }), "UI/OCR-contaminated frames should be held back when clean sources are sufficient")
        expect(!hardened.recommendedReferences.contains(where: {
            $0.sourceInputID == "clean-plus-phone" && $0.id.hasSuffix("person:1")
        }), "a weaker same-view phone-obscured alternate should not dilute a clean board")
        expect(Set(hardened.recommendedReferences.map(\.view)).isSuperset(of: [
            .profile, .threeQuarter, .frontal,
        ]), "hardening should preserve complementary clean views of the subject")
        expect(hardened.recommendedReferences.count == 4,
               "clean evidence should determine board size instead of padding to six slots")

        // Face-only fallback catches a portrait while rejecting tiny profile
        // avatars and decorative UI faces by normalized area.
        let facesOnlyStub = StubAnalyzer(analyses: [analysis(
            faces: [face(0.30, 0.70, 0.16, 0.15),
                    face(0.02, 0.02, 0.01, 0.01)])], featureValues: [1])
        let facesOnly = MimoReferencePreprocessor(analyzer: facesOnlyStub).process([
            MimoReferenceInput(id: "tight-portrait", data: source),
        ])
        expect(facesOnly.images[0].usablePeople.count == 1,
               "a real close portrait should survive while a tiny avatar is rejected")
        expect(facesOnly.images[0].usablePeople[0].coverage == .faceOnly,
               "face-only recovery should be visible in evidence")

        // No-person inputs remain useful for a pet/object workflow through an
        // explicitly lower-confidence, OCR-sanitized full-frame board.
        let empty = analysis(text: [CGRect(x: 0.2, y: 0.45, width: 0.6, height: 0.08)])
        let fallbackStub = StubAnalyzer(analyses: [empty, empty])
        let fallback = MimoReferencePreprocessor(analyzer: fallbackStub).process([
            MimoReferenceInput(id: "possible-pet", data: png(darkBands: true)),
        ])
        expect(!fallback.hasUsablePerson, "fallback frames must not pretend a person was found")
        expect(fallback.images[0].rejectionReason == .noPersonFound,
               "person evidence should explain the miss")
        expect(fallback.providerPayload?.identityBoard.mode == .sanitizedFullFrames,
               "pet/object inputs should receive an explicit sanitized fallback board")
        expect(fallback.providerPayload?.analysisJSON.contains("non_person_or_unresolved") == true,
               "fallback semantics must be explicit to the generation prompt")

        let unavailableStub = StubAnalyzer(analyses: [])
        unavailableStub.analysisErrorsRemaining = 2
        let unavailable = MimoReferencePreprocessor(analyzer: unavailableStub).process([
            MimoReferenceInput(id: "vision-unavailable", data: source),
        ])
        expect(unavailable.images[0].rejectionReason == .analysisFailed,
               "Vision failures should remain visible")
        expect(unavailable.providerPayload == nil,
               "a Vision failure must fail closed before any unsanitized frame can leave the Mac")

        // Fail closed across the whole batch. A successful second image must
        // not mask a Vision/OCR failure in the first image and produce a
        // partially sanitized provider board.
        let mixedFailureStub = StubAnalyzer(analyses: [empty, empty])
        mixedFailureStub.analysisErrorsRemaining = 1
        let mixedFailure = MimoReferencePreprocessor(analyzer: mixedFailureStub).process([
            MimoReferenceInput(id: "analysis-failed", data: source),
            MimoReferenceInput(id: "otherwise-usable-fallback", data: source),
        ])
        expect(mixedFailure.images[0].rejectionReason == .analysisFailed,
               "the failing member of a mixed batch should remain visible")
        expect(mixedFailure.providerPayload == nil,
               "one Vision failure must fail the entire provider payload closed")

        // Cancellation is cooperative and checked around every source image.
        // The first completed analysis flips the closure, so the second image
        // must never reach Vision and no provider payload may be constructed.
        let cancellationStub = StubAnalyzer(analyses: [richAnalysis, richAnalysis])
        let cancelled = MimoReferencePreprocessor(analyzer: cancellationStub).process([
            MimoReferenceInput(id: "first-before-cancel", data: source),
            MimoReferenceInput(id: "second-after-cancel", data: source),
        ], isCancelled: {
            cancellationStub.analysisCallCount >= 1
        })
        expect(cancellationStub.analysisCallCount == 1,
               "cancellation after one input must prevent later Vision work")
        expect(cancelled.images.count == 2 &&
               cancelled.images[1].rejectionReason == .cancelled,
               "unprocessed images should receive deterministic cancellation evidence")
        expect(cancelled.providerPayload == nil,
               "cancelled preprocessing must never expose a provider payload")

        // Byte and pixel limits are enforced before Vision sees the image.
        var tight = MimoReferencePreprocessorConfiguration()
        tight.maximumBytesPerInput = max(1, source.count - 1)
        let cappedStub = StubAnalyzer(analyses: [])
        let capped = MimoReferencePreprocessor(configuration: tight,
                                               analyzer: cappedStub).process([
            MimoReferenceInput(id: "oversized", data: source),
        ])
        expect(capped.images[0].rejectionReason == .inputTooLarge,
               "compressed byte bombs must be rejected")
        expect(cappedStub.analysisCallCount == 0,
               "Vision must not decode byte-rejected inputs")

        var pixelCap = MimoReferencePreprocessorConfiguration()
        pixelCap.maximumSourcePixels = 1_000
        let pixelStub = StubAnalyzer(analyses: [])
        let pixelRejected = MimoReferencePreprocessor(configuration: pixelCap,
                                                      analyzer: pixelStub).process([
            MimoReferenceInput(id: "too-many-pixels", data: source),
        ])
        expect(pixelRejected.images[0].rejectionReason == .pixelLimitExceeded,
               "declared dimensions must be capped before thumbnail decode")
        expect(pixelStub.analysisCallCount == 0,
               "pixel-rejected inputs must not reach Vision")

        var oneOnly = MimoReferencePreprocessorConfiguration()
        oneOnly.maximumInputCount = 1
        let countStub = StubAnalyzer(analyses: [empty, empty])
        let countLimited = MimoReferencePreprocessor(configuration: oneOnly,
                                                     analyzer: countStub).process([
            MimoReferenceInput(id: "first", data: source),
            MimoReferenceInput(id: "extra", data: source),
        ])
        expect(countLimited.images[1].rejectionReason == .tooManyInputs,
               "excess uploads need per-image rejection evidence")

        let fullBodyBox = CGRect(x: 0.30, y: 0.05, width: 0.40, height: 0.85)
        let torsoBox = CGRect(x: 0.32, y: 0.48, width: 0.36, height: 0.40)
        let merged = AppleVisionReferenceAnalyzer.deduplicatePeople([
            MimoReferenceRawPersonObservation(bounds: fullBodyBox, confidence: 0.62,
                                              coverage: .fullBody, source: .fullFrame),
            MimoReferenceRawPersonObservation(bounds: torsoBox, confidence: 0.95,
                                              coverage: .upperBody, source: .fullFrame),
        ])
        expect(merged.count == 1, "overlapping detections of one person must merge")
        expect(merged[0].coverage == .fullBody, "merged coverage keeps full body")
        expect(merged[0].bounds.height >= fullBodyBox.height - 0.001,
               "a confident torso box must not shrink the crop to the waist")
        let samecoverage = AppleVisionReferenceAnalyzer.deduplicatePeople([
            MimoReferenceRawPersonObservation(bounds: fullBodyBox, confidence: 0.62,
                                              coverage: .upperBody, source: .fullFrame),
            MimoReferenceRawPersonObservation(bounds: torsoBox, confidence: 0.95,
                                              coverage: .upperBody, source: .fullFrame),
        ])
        expect(samecoverage.count == 1 && samecoverage[0].bounds == torsoBox,
               "same-coverage merges still trust the confident detection")
        print("reference preprocessor tests passed")
    }
}
