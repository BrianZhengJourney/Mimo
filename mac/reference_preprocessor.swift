// Mimo — privacy-preserving, local reference-photo evidence extraction.
//
// This file deliberately has no network or filesystem code. Image bytes enter
// in memory and the result retains only bounded, cleaned portrait crops plus
// non-identifying geometry/quality metadata.

import AppKit
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

struct MimoReferenceInput {
    let id: String
    let data: Data
}

struct MimoReferencePixelSize: Equatable {
    let width: Int
    let height: Int
}

/// Public-facing rectangles always use a top-left origin. This keeps the
/// evidence easy to draw in AppKit/WebKit without leaking Vision's coordinate
/// convention through the product boundary.
struct MimoReferenceNormalizedRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum MimoReferenceRejectionReason: String, Hashable {
    case cancelled
    case emptyInput
    case tooManyInputs
    case inputTooLarge
    case totalInputTooLarge
    case unreadableImage
    case animatedImage
    case invalidDimensions
    case pixelLimitExceeded
    case analysisFailed
    case noPersonFound
    case onlyTinyPeopleFound
    case portraitEncodingFailed
}

enum MimoReferenceWarning: String, Equatable {
    case collagePanelsScanned
    case textOverlayDetected
    case textOverlayRemoved
    case backgroundIsolationUnavailable
    case facePartlyCoveredByText
    case multiplePeopleDetected
    case identityAmbiguous
    case lowerConfidenceReference
    case visibleTextContamination
    case probableUIOverlay
}

enum MimoReferenceView: String, Equatable {
    case frontal
    case threeQuarter
    case profile
    case unknown
}

enum MimoReferenceCoverage: String, Equatable {
    case fullBody
    case upperBody
    case faceOnly
}

enum MimoReferenceDetectionSource: String, Equatable {
    case fullFrame
    case collageTile
}

struct MimoPersonReferenceEvidence {
    let id: String
    let sourceInputID: String
    let sourceIndex: Int
    let normalizedPersonBounds: MimoReferenceNormalizedRect
    let normalizedCropBounds: MimoReferenceNormalizedRect
    let personConfidence: Float
    let faceConfidence: Float?
    let qualityScore: Float
    let textOverlapRatio: Float
    let view: MimoReferenceView
    let coverage: MimoReferenceCoverage
    let detectionSource: MimoReferenceDetectionSource
    let backgroundRemoved: Bool
    let portraitPixelSize: MimoReferencePixelSize
    let portraitPNG: Data
    let warnings: [MimoReferenceWarning]
}

struct MimoReferenceImageEvidence {
    let inputID: String
    let sourceIndex: Int
    let originalPixelSize: MimoReferencePixelSize?
    let analyzedPixelSize: MimoReferencePixelSize?
    let textRegionCount: Int
    let detectedPersonCount: Int
    let usablePeople: [MimoPersonReferenceEvidence]
    let rejectionReason: MimoReferenceRejectionReason?
    let warnings: [MimoReferenceWarning]

    var isUsable: Bool { !usablePeople.isEmpty && rejectionReason == nil }
}

struct MimoReferencePreprocessingResult {
    let images: [MimoReferenceImageEvidence]
    /// Ranked, bounded, multi-image/multi-angle references suitable for the
    /// provider request. These are aliases of values in `images`; source
    /// screenshots and OCR strings are never retained.
    let recommendedReferences: [MimoPersonReferenceEvidence]
    let providerPayload: MimoReferenceProviderPayload?

    var hasUsablePerson: Bool { !recommendedReferences.isEmpty }
}

struct MimoReferenceIdentityBoard {
    let mode: MimoReferenceIdentityBoardMode
    let png: Data
    let pixelSize: MimoReferencePixelSize
    /// Slot order is left-to-right, then top-to-bottom. No labels are painted
    /// into the image, so the model cannot mistake UI for a design feature.
    let referenceIDs: [String]
    let sourceInputIDs: [String]
}

enum MimoReferenceIdentityBoardMode: String, Equatable {
    case isolatedPeople
    /// No reliable person was found. The board contains locally sanitized
    /// source frames so pets/objects remain a graceful, explicit fallback.
    case sanitizedFullFrames
}

struct MimoReferenceProviderPayload {
    let identityBoard: MimoReferenceIdentityBoard
    /// Safe prompt metadata: no OCR strings, filenames, paths, or source bytes.
    let analysisJSON: String
}

struct MimoReferencePreprocessorConfiguration {
    var maximumInputCount = 8
    var maximumBytesPerInput = 20 * 1024 * 1024
    var maximumTotalInputBytes = 64 * 1024 * 1024
    var maximumSourcePixels = 48_000_000
    var maximumSourceDimension = 12_000
    var analysisMaximumDimension = 2_048
    var portraitMaximumDimension = 1_024
    var maximumPortraitBytes = 6 * 1024 * 1024
    var maximumIdentityBoardBytes = 12 * 1024 * 1024
    var maximumPeoplePerInput = 3
    var maximumRecommendedReferences = 6
    /// A collage may contribute a second complementary panel only when local
    /// identity-feature evidence agrees with the primary subject.
    var maximumRecommendedPerInput = 2
    /// Generic Vision feature-print distances are used only as a conservative
    /// ambiguity guard; missing descriptors never reject an otherwise-usable
    /// upload.
    var maximumIdentityFeatureDistance: Float = 20
    var minimumPersonConfidence: Float = 0.32
    var minimumNormalizedPersonArea: CGFloat = 0.008
    var cropPaddingFraction: CGFloat = 0.18
    /// Text is blurred locally for privacy, but a large blurred patch is still
    /// a misleading visual feature for image generation. Once enough cleaner
    /// uploads exist, keep these crops as evidence but hold them off the board.
    var maximumCleanBoardTextOverlapRatio: Float = 0.03
    /// Dense OCR is a conservative proxy for app/video chrome. It deliberately
    /// does not claim to recognize a particular platform or play icon.
    var probableUISourceTextRegionCount = 10
    /// Do not sacrifice the only useful reference to aggressive cleanup. The
    /// contamination guard activates only after this many distinct clean
    /// uploads establish the subject.
    var minimumCleanSourcesForBoardHardening = 3
    /// A much weaker same-view face from the same collage is usually an
    /// obstruction (phone, hand, sticker), not a useful extra identity angle.
    var weakSameViewAlternateFaceConfidenceGap: Float = 0.12
}

// MARK: - Injectable Vision boundary

struct MimoReferenceRawPersonObservation {
    /// Vision-style normalized rectangle: origin at bottom-left.
    let bounds: CGRect
    let confidence: Float
    let coverage: MimoReferenceCoverage
    let source: MimoReferenceDetectionSource
}

struct MimoReferenceRawFaceObservation {
    /// Vision-style normalized rectangle: origin at bottom-left.
    let bounds: CGRect
    let confidence: Float
    let yawRadians: Float?
}

struct MimoReferenceRawAnalysis {
    let people: [MimoReferenceRawPersonObservation]
    let faces: [MimoReferenceRawFaceObservation]
    /// Vision-style normalized rectangles. Recognized strings are
    /// intentionally discarded at the analyzer boundary.
    let textRegions: [CGRect]
    let usedCollagePasses: Bool
}

protocol MimoReferenceVisionAnalyzing {
    func analyze(_ image: CGImage) throws -> MimoReferenceRawAnalysis
    /// Returns a grayscale person mask. nil is a safe degradation: the crop is
    /// still usable, but its background is not claimed to be removed.
    func personMask(for portrait: CGImage) throws -> CGImage?
    /// A local-only comparison feature. Implementations must not persist or
    /// serialize biometric-like evidence.
    func identityFeature(for faceCrop: CGImage) throws -> MimoReferenceIdentityFeature?
}

class MimoReferenceIdentityFeature {
    func distance(to other: MimoReferenceIdentityFeature) -> Float? { nil }
}

private final class AppleVisionIdentityFeature: MimoReferenceIdentityFeature {
    let observation: VNFeaturePrintObservation

    init(_ observation: VNFeaturePrintObservation) {
        self.observation = observation
    }

    override func distance(to other: MimoReferenceIdentityFeature) -> Float? {
        guard let other = other as? AppleVisionIdentityFeature else { return nil }
        var distance: Float = 0
        do {
            try observation.computeDistance(&distance, to: other.observation)
            return distance
        } catch {
            return nil
        }
    }
}

extension MimoReferenceVisionAnalyzing {
    func identityFeature(for faceCrop: CGImage) throws -> MimoReferenceIdentityFeature? { nil }
}

final class AppleVisionReferenceAnalyzer: MimoReferenceVisionAnalyzing {
    private let tileMinimumPixels = 640

    func analyze(_ image: CGImage) throws -> MimoReferenceRawAnalysis {
        var people: [MimoReferenceRawPersonObservation] = []
        var faces: [MimoReferenceRawFaceObservation] = []

        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let fullPass = try analyzePass(image, region: full, source: .fullFrame,
                                       includeText: true)
        people.append(contentsOf: fullPass.people)
        faces.append(contentsOf: fullPass.faces)

        var textRegions = fullPass.textRegions
        var usedTiles = false
        if min(image.width, image.height) >= tileMinimumPixels {
            usedTiles = true
            // A whole-image pass misses small people in social-media grids.
            // Four overlapping-enough semantic panels preserve resolution for
            // 2x2 collages without guessing at platform-specific chrome.
            let tiles = [
                CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
                CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            ]
            for tile in tiles {
                let pass = try analyzePass(image, region: tile, source: .collageTile,
                                           includeText: false)
                people.append(contentsOf: pass.people)
                faces.append(contentsOf: pass.faces)
            }
        }

        people = Self.deduplicatePeople(people)
        faces = Self.deduplicateFaces(faces)
        textRegions = Self.deduplicateRects(textRegions, threshold: 0.75)
        return MimoReferenceRawAnalysis(people: people, faces: faces,
                                        textRegions: textRegions,
                                        usedCollagePasses: usedTiles)
    }

    func personMask(for portrait: CGImage) throws -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: portrait, options: [:])
        try handler.perform([request])
        guard let pixelBuffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // A zero-dimension buffer made `baseAddress` nil and the force-unwrap
        // trapped — a hard crash in a path whose contract (see the doc above)
        // is that returning nil is the safe degradation.
        guard width > 0, height > 0, sourceRowBytes >= width else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        // one withUnsafeMutableBytes for the whole copy, not one per row
        bytes.withUnsafeMutableBytes { destination in
            guard let target = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(target.advanced(by: row * width),
                       base.advanced(by: row * sourceRowBytes), width)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    func identityFeature(for faceCrop: CGImage) throws -> MimoReferenceIdentityFeature? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: faceCrop, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return AppleVisionIdentityFeature(observation)
    }

    private func analyzePass(_ image: CGImage, region: CGRect,
                             source: MimoReferenceDetectionSource,
                             includeText: Bool) throws -> MimoReferenceRawAnalysis {
        guard let pixelRect = Self.pixelRect(for: region, in: image),
              let tile = image.cropping(to: pixelRect) else {
            return MimoReferenceRawAnalysis(people: [], faces: [], textRegions: [],
                                            usedCollagePasses: source == .collageTile)
        }

        let fullBody = VNDetectHumanRectanglesRequest()
        fullBody.upperBodyOnly = false
        let upperBody = VNDetectHumanRectanglesRequest()
        upperBody.upperBodyOnly = true
        let face = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        // Small Chinese captions are common in social screenshots. Accurate
        // bilingual OCR is still local and materially reduces text leaking
        // into the identity evidence board.
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["zh-Hans", "en-US"]
        text.usesLanguageCorrection = false
        text.minimumTextHeight = 0.006

        var requests: [VNRequest] = [fullBody, upperBody, face]
        if includeText { requests.append(text) }
        try VNImageRequestHandler(cgImage: tile, options: [:]).perform(requests)

        var people: [MimoReferenceRawPersonObservation] = []
        for observation in fullBody.results ?? [] where
            !Self.touchesInternalTileEdge(observation.boundingBox, region: region) {
            people.append(MimoReferenceRawPersonObservation(
                bounds: Self.toGlobal(observation.boundingBox, within: region),
                confidence: observation.confidence, coverage: .fullBody, source: source))
        }
        for observation in upperBody.results ?? [] where
            !Self.touchesInternalTileEdge(observation.boundingBox, region: region) {
            people.append(MimoReferenceRawPersonObservation(
                bounds: Self.toGlobal(observation.boundingBox, within: region),
                confidence: observation.confidence, coverage: .upperBody, source: source))
        }
        let faces = (face.results ?? []).filter {
            !Self.touchesInternalTileEdge($0.boundingBox, region: region)
        }.map { observation in
            MimoReferenceRawFaceObservation(
                bounds: Self.toGlobal(observation.boundingBox, within: region),
                confidence: observation.confidence,
                yawRadians: observation.yaw?.floatValue)
        }
        let texts = includeText ? (text.results ?? []).map(\.boundingBox) : []
        return MimoReferenceRawAnalysis(people: people, faces: faces,
                                        textRegions: texts,
                                        usedCollagePasses: source == .collageTile)
    }

    private static func pixelRect(for normalized: CGRect, in image: CGImage) -> CGRect? {
        let rect = CGRect(x: normalized.minX * CGFloat(image.width),
                          y: (1 - normalized.maxY) * CGFloat(image.height),
                          width: normalized.width * CGFloat(image.width),
                          height: normalized.height * CGFloat(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return rect.isNull || rect.width < 2 || rect.height < 2 ? nil : rect
    }

    private static func toGlobal(_ local: CGRect, within region: CGRect) -> CGRect {
        CGRect(x: region.minX + local.minX * region.width,
               y: region.minY + local.minY * region.height,
               width: local.width * region.width,
               height: local.height * region.height)
    }

    private static func touchesInternalTileEdge(_ local: CGRect, region: CGRect) -> Bool {
        guard region.width < 0.99 || region.height < 0.99 else { return false }
        let tolerance: CGFloat = 0.025
        return (region.minX > 0 && local.minX <= tolerance) ||
            (region.maxX < 1 && local.maxX >= 1 - tolerance) ||
            (region.minY > 0 && local.minY <= tolerance) ||
            (region.maxY < 1 && local.maxY >= 1 - tolerance)
    }

    static func deduplicatePeople(_ observations: [MimoReferenceRawPersonObservation])
        -> [MimoReferenceRawPersonObservation] {
        observations.sorted { lhs, rhs in
            let lhsRank = lhs.confidence + (lhs.coverage == .fullBody ? 0.05 : 0)
            let rhsRank = rhs.confidence + (rhs.coverage == .fullBody ? 0.05 : 0)
            return lhsRank > rhsRank
        }.reduce(into: []) { kept, candidate in
            if let index = kept.firstIndex(where: {
                iou($0.bounds, candidate.bounds) >= 0.45 ||
                containment($0.bounds, candidate.bounds) >= 0.78
            }) {
                let existing = kept[index]
                let preferredCoverage: MimoReferenceCoverage =
                    existing.coverage == .fullBody || candidate.coverage == .fullBody
                    ? .fullBody : .upperBody
                // The torso detector often outscores the full-body one on the
                // same person; picking bounds by confidence alone used to crop
                // full-body references at the waist. Differing coverages keep
                // the union so the whole person survives the merge.
                let bounds: CGRect
                if existing.coverage == candidate.coverage {
                    bounds = existing.confidence >= candidate.confidence
                        ? existing.bounds : candidate.bounds
                } else {
                    bounds = existing.bounds.union(candidate.bounds)
                }
                kept[index] = MimoReferenceRawPersonObservation(
                    bounds: bounds,
                    confidence: max(existing.confidence, candidate.confidence),
                    coverage: preferredCoverage,
                    source: existing.source == .fullFrame || candidate.source == .fullFrame
                    ? .fullFrame : .collageTile)
            } else {
                kept.append(candidate)
            }
        }
    }

    private static func deduplicateFaces(_ observations: [MimoReferenceRawFaceObservation])
        -> [MimoReferenceRawFaceObservation] {
        observations.sorted { $0.confidence > $1.confidence }.reduce(into: []) { kept, candidate in
            if !kept.contains(where: { iou($0.bounds, candidate.bounds) >= 0.55 }) {
                kept.append(candidate)
            }
        }
    }

    private static func deduplicateRects(_ rects: [CGRect], threshold: CGFloat) -> [CGRect] {
        rects.reduce(into: []) { kept, candidate in
            if !kept.contains(where: { iou($0, candidate) >= threshold }) {
                kept.append(candidate)
            }
        }
    }
}

// MARK: - Preprocessor

final class MimoReferencePreprocessor {
    private let configuration: MimoReferencePreprocessorConfiguration
    private let analyzer: MimoReferenceVisionAnalyzing
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(configuration: MimoReferencePreprocessorConfiguration = .init(),
         analyzer: MimoReferenceVisionAnalyzing = AppleVisionReferenceAnalyzer()) {
        self.configuration = configuration
        self.analyzer = analyzer
    }

    /// CPU/Neural Engine work can be substantial; call this method from a
    /// background queue. It is synchronous so cancellation and paid-provider
    /// request lifecycles remain under the app's control.
    func process(_ inputs: [MimoReferenceInput]) -> MimoReferencePreprocessingResult {
        process(inputs, isCancelled: { false })
    }

    /// Cooperative cancellation never returns a provider payload. The closure
    /// is intentionally synchronous so callers can pass a DispatchWorkItem or
    /// generation-token check without introducing shared mutable state here.
    func process(_ inputs: [MimoReferenceInput], isCancelled: () -> Bool)
        -> MimoReferencePreprocessingResult {
        var evidence: [MimoReferenceImageEvidence] = []
        // Exists only for the duration of this call. Neither feature prints nor
        // source photos enter the returned value or any persistence layer.
        var identityFeatures: [String: MimoReferenceIdentityFeature] = [:]
        // Scratch, local to this call — same lifetime as identityFeatures, so
        // no analysis outlives the request that produced it.
        var analyzedFrames: [Int: AnalyzedFrame] = [:]
        var totalBytes = 0

        for (index, input) in inputs.enumerated() {
            guard !isCancelled() else {
                return cancelledResult(inputs: inputs, evidence: evidence)
            }
            if index >= configuration.maximumInputCount {
                evidence.append(rejected(input, index: index, reason: .tooManyInputs))
            } else if input.data.isEmpty {
                evidence.append(rejected(input, index: index, reason: .emptyInput))
            } else if input.data.count > configuration.maximumBytesPerInput {
                evidence.append(rejected(input, index: index, reason: .inputTooLarge))
            } else if totalBytes > configuration.maximumTotalInputBytes - input.data.count {
                evidence.append(rejected(input, index: index, reason: .totalInputTooLarge))
            } else {
                totalBytes += input.data.count
                evidence.append(processOne(input, index: index,
                                           identityFeatures: &identityFeatures,
                                           analyzedFrames: &analyzedFrames))
            }
            guard !isCancelled() else {
                return cancelledResult(inputs: inputs, evidence: evidence)
            }
        }

        // OCR is part of the Vision analysis. If any accepted image could not
        // be analyzed, do not silently build a partial board from its siblings.
        // This is the privacy boundary: uncertain sanitation means no upload.
        guard !evidence.contains(where: { $0.rejectionReason == .analysisFailed }) else {
            return MimoReferencePreprocessingResult(images: evidence,
                                                    recommendedReferences: [],
                                                    providerPayload: nil)
        }
        guard !isCancelled() else {
            return cancelledResult(inputs: inputs, evidence: evidence)
        }
        let selected = selectReferences(from: evidence.flatMap(\.usablePeople),
                                        identityFeatures: identityFeatures)
        // Board construction allocates and encodes a 1024px image. Give the
        // caller one final deterministic cancellation point before that work.
        guard !isCancelled() else {
            return cancelledResult(inputs: inputs, evidence: evidence)
        }
        let payload = selected.isEmpty
            ? makeFallbackProviderPayload(inputs: inputs, evidence: evidence,
                                          analyzedFrames: analyzedFrames,
                                          isCancelled: isCancelled)
            : makeProviderPayload(from: selected, isCancelled: isCancelled)
        guard !isCancelled() else {
            return cancelledResult(inputs: inputs, evidence: evidence)
        }
        return MimoReferencePreprocessingResult(images: evidence,
                                                recommendedReferences: selected,
                                                providerPayload: payload)
    }

    private func cancelledResult(inputs: [MimoReferenceInput],
                                 evidence: [MimoReferenceImageEvidence])
        -> MimoReferencePreprocessingResult {
        var images = evidence
        if images.count < inputs.count {
            for index in images.count..<inputs.count {
                images.append(rejected(inputs[index], index: index, reason: .cancelled))
            }
        }
        return MimoReferencePreprocessingResult(images: images,
                                                recommendedReferences: [],
                                                providerPayload: nil)
    }

    /// Everything the fallback board needs that `processOne` already computed.
    /// Recomputing it means a second full Vision pass — two person requests, a
    /// face request, and accurate bilingual OCR, across the full frame and four
    /// collage tiles — for images that were just analyzed.
    struct AnalyzedFrame {
        let image: CGImage
        let textRegions: [CGRect]
    }

    private func processOne(_ input: MimoReferenceInput, index: Int,
                            identityFeatures: inout [String: MimoReferenceIdentityFeature],
                            analyzedFrames: inout [Int: AnalyzedFrame])
        -> MimoReferenceImageEvidence {
        let decoded: DecodedReferenceImage
        do {
            decoded = try decode(input.data)
        } catch let reason as MimoReferenceRejectionReason {
            return rejected(input, index: index, reason: reason)
        } catch {
            return rejected(input, index: index, reason: .unreadableImage)
        }

        let analysis: MimoReferenceRawAnalysis
        do {
            analysis = try analyzer.analyze(decoded.image)
        } catch {
            return MimoReferenceImageEvidence(
                inputID: input.id, sourceIndex: index,
                originalPixelSize: decoded.originalSize,
                analyzedPixelSize: decoded.analysisSize,
                textRegionCount: 0, detectedPersonCount: 0, usablePeople: [],
                rejectionReason: .analysisFailed, warnings: [])
        }

        analyzedFrames[index] = AnalyzedFrame(image: decoded.image,
                                              textRegions: analysis.textRegions)

        let candidates = buildCandidates(analysis)
        let areaQualified = candidates.filter {
            $0.person.confidence >= configuration.minimumPersonConfidence &&
            $0.person.bounds.width * $0.person.bounds.height >=
                configuration.minimumNormalizedPersonArea
        }

        var people: [MimoPersonReferenceEvidence] = []
        for (candidateIndex, candidate) in areaQualified.prefix(configuration.maximumPeoplePerInput)
            .enumerated() {
            if let rendered = render(candidate, from: decoded.image,
                                     textRegions: analysis.textRegions),
               rendered.png.count <= configuration.maximumPortraitBytes {
                let warnings = warnings(for: candidate, rendered: rendered,
                                        peopleCount: candidates.count,
                                        sourceTextRegionCount: analysis.textRegions.count)
                let referenceID = "\(input.id):person:\(candidateIndex)"
                people.append(MimoPersonReferenceEvidence(
                    id: referenceID,
                    sourceInputID: input.id, sourceIndex: index,
                    normalizedPersonBounds: topLeftRect(candidate.person.bounds),
                    normalizedCropBounds: topLeftRect(rendered.cropBounds),
                    personConfidence: candidate.person.confidence,
                    faceConfidence: candidate.face?.confidence,
                    qualityScore: candidate.qualityScore,
                    textOverlapRatio: candidate.textOverlapRatio,
                    view: view(for: candidate.face?.yawRadians),
                    coverage: candidate.person.coverage,
                    detectionSource: candidate.person.source,
                    backgroundRemoved: rendered.backgroundRemoved,
                    portraitPixelSize: rendered.size, portraitPNG: rendered.png,
                    warnings: warnings))
                if let feature = identityFeature(for: candidate, in: decoded.image) {
                    identityFeatures[referenceID] = feature
                }
            }
        }

        let reason: MimoReferenceRejectionReason?
        if !people.isEmpty { reason = nil }
        else if candidates.isEmpty { reason = .noPersonFound }
        else if areaQualified.isEmpty { reason = .onlyTinyPeopleFound }
        else { reason = .portraitEncodingFailed }

        var imageWarnings: [MimoReferenceWarning] = []
        if analysis.usedCollagePasses { imageWarnings.append(.collagePanelsScanned) }
        if !analysis.textRegions.isEmpty { imageWarnings.append(.textOverlayDetected) }
        if candidates.count > 1 { imageWarnings.append(.multiplePeopleDetected) }
        if people.count > 1 && people.filter({ identityFeatures[$0.id] != nil }).count < 2 {
            imageWarnings.append(.identityAmbiguous)
        }
        return MimoReferenceImageEvidence(
            inputID: input.id, sourceIndex: index,
            originalPixelSize: decoded.originalSize,
            analyzedPixelSize: decoded.analysisSize,
            textRegionCount: analysis.textRegions.count,
            detectedPersonCount: candidates.count, usablePeople: people,
            rejectionReason: reason, warnings: imageWarnings)
    }

    private func rejected(_ input: MimoReferenceInput, index: Int,
                          reason: MimoReferenceRejectionReason)
        -> MimoReferenceImageEvidence {
        MimoReferenceImageEvidence(
            inputID: input.id, sourceIndex: index,
            originalPixelSize: nil, analyzedPixelSize: nil,
            textRegionCount: 0, detectedPersonCount: 0, usablePeople: [],
            rejectionReason: reason, warnings: [])
    }

    private struct DecodedReferenceImage {
        let image: CGImage
        let originalSize: MimoReferencePixelSize
        let analysisSize: MimoReferencePixelSize
    }

    private func decode(_ data: Data) throws -> DecodedReferenceImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MimoReferenceRejectionReason.unreadableImage
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw MimoReferenceRejectionReason.animatedImage
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MimoReferenceRejectionReason.invalidDimensions
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0,
              width <= configuration.maximumSourceDimension,
              height <= configuration.maximumSourceDimension else {
            throw MimoReferenceRejectionReason.invalidDimensions
        }
        guard width <= configuration.maximumSourcePixels / height else {
            throw MimoReferenceRejectionReason.pixelLimitExceeded
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: configuration.analysisMaximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary) else {
            throw MimoReferenceRejectionReason.unreadableImage
        }
        return DecodedReferenceImage(
            image: image,
            originalSize: MimoReferencePixelSize(width: width, height: height),
            analysisSize: MimoReferencePixelSize(width: image.width, height: image.height))
    }

    private struct Candidate {
        let person: MimoReferenceRawPersonObservation
        let face: MimoReferenceRawFaceObservation?
        let textOverlapRatio: Float
        let faceTextOverlapRatio: Float
        let qualityScore: Float
    }

    private func buildCandidates(_ analysis: MimoReferenceRawAnalysis) -> [Candidate] {
        var people = analysis.people.filter { validNormalized($0.bounds) }
        let validFaces = analysis.faces.filter { validNormalized($0.bounds) }

        // Face-only fallback is essential for tight portraits, while the area
        // gate below prevents tiny profile avatars and UI thumbnails from
        // becoming generation references.
        for face in validFaces where !people.contains(where: {
            $0.bounds.insetBy(dx: -0.02, dy: -0.02).contains(
                CGPoint(x: face.bounds.midX, y: face.bounds.midY))
        }) {
            let estimated = estimatedPersonBounds(from: face.bounds)
            people.append(MimoReferenceRawPersonObservation(
                bounds: estimated, confidence: face.confidence * 0.9,
                coverage: .faceOnly, source: .fullFrame))
        }

        return people.map { person in
            let face = validFaces.filter { candidateFace in
                person.bounds.insetBy(dx: -0.03, dy: -0.03).contains(
                    CGPoint(x: candidateFace.bounds.midX, y: candidateFace.bounds.midY))
            }.max(by: { $0.confidence < $1.confidence })
            let personText = overlapRatio(of: person.bounds, with: analysis.textRegions)
            let faceText = face.map { overlapRatio(of: $0.bounds,
                                                   with: analysis.textRegions) } ?? 0
            let area = min(1, Float(person.bounds.width * person.bounds.height / 0.20))
            let centerDistance = hypot(Float(person.bounds.midX - 0.5),
                                       Float(person.bounds.midY - 0.5))
            let centered = max(0, 1 - centerDistance / 0.71)
            let faceSignal = face?.confidence ?? 0
            let score = min(1, max(0,
                person.confidence * 0.42 + area * 0.20 + faceSignal * 0.23 +
                centered * 0.10 + (1 - min(1, personText)) * 0.05 -
                min(0.18, faceText * 0.22)))
            return Candidate(person: person, face: face,
                             textOverlapRatio: personText,
                             faceTextOverlapRatio: faceText,
                             qualityScore: score)
        }.sorted {
            if $0.qualityScore == $1.qualityScore {
                return $0.person.bounds.width * $0.person.bounds.height >
                    $1.person.bounds.width * $1.person.bounds.height
            }
            return $0.qualityScore > $1.qualityScore
        }
    }

    private struct RenderedPortrait {
        let png: Data
        let size: MimoReferencePixelSize
        let cropBounds: CGRect
        let backgroundRemoved: Bool
        let removedText: Bool
    }

    private func render(_ candidate: Candidate, from image: CGImage,
                        textRegions: [CGRect]) -> RenderedPortrait? {
        let cropBounds = paddedCrop(candidate.person.bounds,
                                    face: candidate.face?.bounds)
        let imageExtent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelCrop = CGRect(x: cropBounds.minX * CGFloat(image.width),
                               y: (1 - cropBounds.maxY) * CGFloat(image.height),
                               width: cropBounds.width * CGFloat(image.width),
                               height: cropBounds.height * CGFloat(image.height))
            .integral.intersection(imageExtent)
        guard !pixelCrop.isNull, pixelCrop.width >= 8, pixelCrop.height >= 8,
              let rawCrop = image.cropping(to: pixelCrop) else { return nil }
        let longest = max(pixelCrop.width, pixelCrop.height)
        let resize = min(1, CGFloat(configuration.portraitMaximumDimension) / longest)
        let outputWidth = max(8, Int(floor(pixelCrop.width * resize)))
        let outputHeight = max(8, Int(floor(pixelCrop.height * resize)))
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let mask = try? analyzer.personMask(for: rawCrop)
        guard let base = makeRGBAImage(width: outputWidth, height: outputHeight, draw: { context in
            context.setFillColor(CGColor(red: 241 / 255, green: 236 / 255,
                                         blue: 226 / 255, alpha: 1))
            context.fill(outputRect)
            context.interpolationQuality = .high
            if let mask {
                context.saveGState()
                context.clip(to: outputRect, mask: mask)
                context.draw(rawCrop, in: outputRect)
                context.restoreGState()
            } else {
                context.draw(rawCrop, in: outputRect)
            }
        }) else { return nil }
        let textRects = textRegions.compactMap { text -> CGRect? in
            let overlap = text.intersection(cropBounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            let x = (overlap.minX - cropBounds.minX) / cropBounds.width * CGFloat(outputWidth)
            let y = (overlap.minY - cropBounds.minY) / cropBounds.height * CGFloat(outputHeight)
            let width = overlap.width / cropBounds.width * CGFloat(outputWidth)
            let height = overlap.height / cropBounds.height * CGFloat(outputHeight)
            let expandX = max(5, width * 0.08)
            let expandY = max(4, height * 0.60)
            return CGRect(x: x - expandX, y: y - expandY,
                          width: width + expandX * 2,
                          height: height + expandY * 2).intersection(outputRect)
        }
        let obscured = obscureText(in: base, regions: textRects)
        guard let png = encodePNG(obscured.image) else { return nil }
        return RenderedPortrait(
            png: png,
            size: MimoReferencePixelSize(width: obscured.image.width,
                                         height: obscured.image.height),
            cropBounds: cropBounds, backgroundRemoved: mask != nil,
            removedText: obscured.didObscure)
    }

    private func warnings(for candidate: Candidate, rendered: RenderedPortrait,
                          peopleCount: Int,
                          sourceTextRegionCount: Int) -> [MimoReferenceWarning] {
        var warnings: [MimoReferenceWarning] = []
        if rendered.removedText { warnings.append(.textOverlayRemoved) }
        if !rendered.backgroundRemoved { warnings.append(.backgroundIsolationUnavailable) }
        if candidate.faceTextOverlapRatio > 0.12 { warnings.append(.facePartlyCoveredByText) }
        if peopleCount > 1 { warnings.append(.multiplePeopleDetected) }
        if candidate.qualityScore < 0.55 { warnings.append(.lowerConfidenceReference) }
        if candidate.textOverlapRatio > configuration.maximumCleanBoardTextOverlapRatio {
            warnings.append(.visibleTextContamination)
        }
        if sourceTextRegionCount >= configuration.probableUISourceTextRegionCount {
            warnings.append(.probableUIOverlay)
        }
        return warnings
    }

    private func selectReferences(
        from people: [MimoPersonReferenceEvidence],
        identityFeatures: [String: MimoReferenceIdentityFeature]
    )
        -> [MimoPersonReferenceEvidence] {
        let allSorted = people.sorted {
            if $0.qualityScore == $1.qualityScore { return $0.sourceIndex < $1.sourceIndex }
            return $0.qualityScore > $1.qualityScore
        }
        let cleanSourceIDs = Set(allSorted.filter(isCleanBoardReference).map(\.sourceInputID))
        let shouldHarden = cleanSourceIDs.count >=
            configuration.minimumCleanSourcesForBoardHardening
        var sorted = shouldHarden
            ? allSorted.filter(isCleanBoardReference)
            : allSorted

        // A phone-obscured face can still receive a plausible Vision face box.
        // Suppress it only when a clearly stronger crop of the same view exists
        // in the same upload and the batch already has enough clean sources.
        // Sole low-confidence profiles are preserved because they often provide
        // the most valuable complementary identity angle.
        if shouldHarden {
            sorted = sorted.filter { candidate in
                guard let candidateFace = candidate.faceConfidence else { return true }
                return !sorted.contains { stronger in
                    guard stronger.id != candidate.id,
                          stronger.sourceInputID == candidate.sourceInputID,
                          let strongerFace = stronger.faceConfidence,
                          strongerFace - candidateFace >=
                            configuration.weakSameViewAlternateFaceConfidenceGap,
                          stronger.qualityScore >= candidate.qualityScore else { return false }
                    return stronger.view == candidate.view || candidate.view == .unknown
                }
            }
        }
        var selected: [MimoPersonReferenceEvidence] = []
        var perInput: [String: Int] = [:]
        var representedViews: Set<MimoReferenceView> = []

        let sourceIDs = Dictionary(grouping: sorted, by: \.sourceInputID).values
            .sorted { lhs, rhs in
                (lhs.map(\.sourceIndex).min() ?? .max) < (rhs.map(\.sourceIndex).min() ?? .max)
            }
        let primaryGroup = sourceIDs.first
        let primary = primaryGroup?.first(where: { identityFeatures[$0.id] != nil }) ??
            primaryGroup?.first ??
            sorted.first(where: { identityFeatures[$0.id] != nil }) ?? sorted.first
        let anchorFeature = primary.flatMap { identityFeatures[$0.id] }

        // Pick one dominant subject per upload. If the primary has a local
        // face feature, a multi-person collage contributes only the closest
        // candidate, and an unambiguously distant face is excluded.
        for group in sourceIDs {
            guard selected.count < configuration.maximumRecommendedReferences else { break }
            let chosen: MimoPersonReferenceEvidence?
            if let primary, group.contains(where: { $0.id == primary.id }) {
                chosen = primary
            } else if let anchorFeature {
                let distances = group.compactMap { person -> (MimoPersonReferenceEvidence, Float)? in
                    guard let feature = identityFeatures[person.id],
                          let distance = anchorFeature.distance(to: feature) else { return nil }
                    return (person, distance)
                }.sorted { $0.1 < $1.1 }
                if let nearest = distances.first {
                    chosen = nearest.1 <= configuration.maximumIdentityFeatureDistance
                        ? nearest.0 : nil
                } else {
                    chosen = group.first
                }
            } else {
                chosen = group.first
            }
            guard let chosen else { continue }
            selected.append(chosen)
            perInput[chosen.sourceInputID] = 1
            if chosen.view != .unknown { representedViews.insert(chosen.view) }
        }
        // Then add alternate angles/panels without letting one collage flood
        // the provider request and dilute identity evidence.
        for person in sorted {
            guard selected.count < configuration.maximumRecommendedReferences else { break }
            guard !selected.contains(where: { $0.id == person.id }),
                  perInput[person.sourceInputID, default: 0] <
                    configuration.maximumRecommendedPerInput else { continue }
            guard isSpatiallyDistinct(person, from: selected.filter {
                $0.sourceInputID == person.sourceInputID
            }) else { continue }
            let identityCompatible: Bool
            if let anchorFeature, let feature = identityFeatures[person.id],
               let distance = anchorFeature.distance(to: feature) {
                identityCompatible = distance <= configuration.maximumIdentityFeatureDistance
            } else {
                identityCompatible = false
            }
            if identityCompatible && person.view != .unknown &&
                !representedViews.contains(person.view) {
                selected.append(person)
                perInput[person.sourceInputID, default: 0] += 1
                representedViews.insert(person.view)
            }
        }
        for person in sorted {
            guard selected.count < configuration.maximumRecommendedReferences else { break }
            guard !selected.contains(where: { $0.id == person.id }),
                  perInput[person.sourceInputID, default: 0] <
                    configuration.maximumRecommendedPerInput else { continue }
            guard isSpatiallyDistinct(person, from: selected.filter {
                $0.sourceInputID == person.sourceInputID
            }) else { continue }
            guard let anchorFeature, let feature = identityFeatures[person.id],
                  let distance = anchorFeature.distance(to: feature),
                  distance <= configuration.maximumIdentityFeatureDistance else { continue }
            selected.append(person)
            perInput[person.sourceInputID, default: 0] += 1
        }
        return selected
    }

    private func isCleanBoardReference(_ reference: MimoPersonReferenceEvidence) -> Bool {
        !reference.warnings.contains(.visibleTextContamination) &&
            !reference.warnings.contains(.probableUIOverlay) &&
            !reference.warnings.contains(.facePartlyCoveredByText)
    }

    private func isSpatiallyDistinct(
        _ candidate: MimoPersonReferenceEvidence,
        from existing: [MimoPersonReferenceEvidence]
    ) -> Bool {
        let candidateRect = CGRect(x: candidate.normalizedPersonBounds.x,
                                   y: candidate.normalizedPersonBounds.y,
                                   width: candidate.normalizedPersonBounds.width,
                                   height: candidate.normalizedPersonBounds.height)
        return existing.allSatisfy { reference in
            let rect = CGRect(x: reference.normalizedPersonBounds.x,
                              y: reference.normalizedPersonBounds.y,
                              width: reference.normalizedPersonBounds.width,
                              height: reference.normalizedPersonBounds.height)
            let centerDistance = hypot(candidateRect.midX - rect.midX,
                                       candidateRect.midY - rect.midY)
            return iou(candidateRect, rect) < 0.35 && centerDistance > 0.12
        }
    }

    private func identityFeature(for candidate: Candidate, in image: CGImage)
        -> MimoReferenceIdentityFeature? {
        guard let face = candidate.face else { return nil }
        let padded = face.bounds.insetBy(dx: -face.bounds.width * 0.28,
                                         dy: -face.bounds.height * 0.28)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let extent = CGRect(x: padded.minX * CGFloat(image.width),
                            y: (1 - padded.maxY) * CGFloat(image.height),
                            width: padded.width * CGFloat(image.width),
                            height: padded.height * CGFloat(image.height)).integral
        guard extent.width >= 32, extent.height >= 32,
              let crop = image.cropping(to: extent) else { return nil }
        return try? analyzer.identityFeature(for: crop)
    }

    private func makeProviderPayload(from references: [MimoPersonReferenceEvidence],
                                     isCancelled: () -> Bool)
        -> MimoReferenceProviderPayload? {
        guard !references.isEmpty, !isCancelled(),
              let board = makeIdentityBoard(references) else { return nil }
        let entries: [[String: Any]] = references.enumerated().map { index, reference in
            [
                "slot": index + 1,
                "role": index == 0 ? "primary_anchor" : "supporting",
                "source_index": reference.sourceIndex,
                "view": reference.view.rawValue,
                "coverage": reference.coverage.rawValue,
                "quality_score": rounded(reference.qualityScore),
                "person_confidence": rounded(reference.personConfidence),
                "face_confidence": reference.faceConfidence.map { rounded($0) as Any } ?? NSNull(),
                "background_removed": reference.backgroundRemoved,
                "text_removed": reference.warnings.contains(.textOverlayRemoved),
                "face_text_warning": reference.warnings.contains(.facePartlyCoveredByText),
                "visible_text_warning": reference.warnings.contains(.visibleTextContamination),
                "probable_ui_warning": reference.warnings.contains(.probableUIOverlay),
            ]
        }
        let json: [String: Any] = [
            "schema": "mimo.reference-evidence.v1",
            "identity_scope": "user_selected_same_subject_unverified",
            "board_mode": board.mode.rawValue,
            "instructions": [
                "Use the people, not their source background, UI, or text.",
                "Slot 1 is the primary identity anchor: face, hair, skin tone, outfit, and overall proportions come from it.",
                "Supporting slots only contribute views, angles, and expressions the primary lacks; when they disagree with slot 1, slot 1 wins.",
            ],
            "reference_count": references.count,
            "references": entries,
        ]
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.sortedKeys]),
              let analysisJSON = String(data: data, encoding: .utf8) else { return nil }
        return MimoReferenceProviderPayload(identityBoard: board,
                                            analysisJSON: analysisJSON)
    }

    private func makeIdentityBoard(_ references: [MimoPersonReferenceEvidence])
        -> MimoReferenceIdentityBoard? {
        let slots = references.map {
            BoardSlot(id: $0.id, sourceInputID: $0.sourceInputID, png: $0.portraitPNG)
        }
        return makeBoard(slots, mode: .isolatedPeople)
    }

    private struct BoardSlot {
        let id: String
        let sourceInputID: String
        let png: Data
    }

    private func makeBoard(_ slots: [BoardSlot], mode: MimoReferenceIdentityBoardMode)
        -> MimoReferenceIdentityBoard? {
        guard !slots.isEmpty else { return nil }
        let columns = min(3, slots.count)
        let rows = Int(ceil(Double(slots.count) / Double(columns)))
        let boardWidth = 1_024
        let boardHeight = 1_024
        let gap: CGFloat = 18
        let boardExtent = CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight)
        let cellWidth = (CGFloat(boardWidth) - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (CGFloat(boardHeight) - gap * CGFloat(rows + 1)) / CGFloat(rows)
        let decoded: [CGImage] = slots.compactMap { slot in
            guard let source = CGImageSourceCreateWithData(slot.png as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard decoded.count == slots.count,
              let output = makeRGBAImage(width: boardWidth, height: boardHeight, draw: { context in
            context.setFillColor(CGColor(red: 241 / 255, green: 236 / 255,
                                         blue: 226 / 255, alpha: 1))
            context.fill(boardExtent)
            context.interpolationQuality = .high
            for (index, image) in decoded.enumerated() {
                let scale = min(cellWidth / CGFloat(image.width),
                                cellHeight / CGFloat(image.height))
                let fittedWidth = CGFloat(image.width) * scale
                let fittedHeight = CGFloat(image.height) * scale
                let column = index % columns
                let topRow = index / columns
                let row = rows - topRow - 1
                let x = gap + CGFloat(column) * (cellWidth + gap) +
                    (cellWidth - fittedWidth) / 2
                let y = gap + CGFloat(row) * (cellHeight + gap) +
                    (cellHeight - fittedHeight) / 2
                context.draw(image, in: CGRect(x: x, y: y,
                                               width: fittedWidth, height: fittedHeight))
            }
        }),
              let png = encodePNG(output),
              png.count <= configuration.maximumIdentityBoardBytes else { return nil }
        return MimoReferenceIdentityBoard(
            mode: mode, png: png,
            pixelSize: MimoReferencePixelSize(width: output.width, height: output.height),
            referenceIDs: slots.map(\.id),
            sourceInputIDs: slots.map(\.sourceInputID))
    }

    private func makeFallbackProviderPayload(
        inputs: [MimoReferenceInput], evidence: [MimoReferenceImageEvidence],
        analyzedFrames: [Int: AnalyzedFrame],
        isCancelled: () -> Bool
    ) -> MimoReferenceProviderPayload? {
        let fallbackReasons: Set<MimoReferenceRejectionReason> = [
            .noPersonFound, .onlyTinyPeopleFound,
        ]
        var slots: [BoardSlot] = []
        var metadata: [[String: Any]] = []
        for imageEvidence in evidence.sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
            guard !isCancelled() else { return nil }
            guard slots.count < min(3, configuration.maximumRecommendedReferences),
                  let reason = imageEvidence.rejectionReason,
                  fallbackReasons.contains(reason),
                  inputs.indices.contains(imageEvidence.sourceIndex) else { continue }
            let input = inputs[imageEvidence.sourceIndex]
            // Reuse the analysis processOne already ran for this image. Falling
            // back to a fresh decode+analyze is correct but expensive, so it is
            // only the path when the scratch entry is missing.
            let frame: AnalyzedFrame
            if let cached = analyzedFrames[imageEvidence.sourceIndex] {
                frame = cached
            } else if let decoded = try? decode(input.data),
                      let fresh = try? analyzer.analyze(decoded.image) {
                frame = AnalyzedFrame(image: decoded.image, textRegions: fresh.textRegions)
            } else {
                // One unreadable image must not discard slots already built:
                // this is a best-effort "up to 3 slots" gather.
                continue
            }
            guard !isCancelled() else { return nil }
            guard let cleaned = renderSanitizedFullFrame(
                frame.image, textRegions: frame.textRegions) else { continue }
            let id = "\(input.id):fallback"
            slots.append(BoardSlot(id: id, sourceInputID: input.id, png: cleaned.png))
            metadata.append([
                "slot": slots.count,
                "source_index": imageEvidence.sourceIndex,
                "text_removed": cleaned.removedText,
                "dark_chrome_trimmed": cleaned.trimmedChrome,
                "vision_analysis_available": true,
            ])
        }
        guard !isCancelled(),
              let board = makeBoard(slots, mode: .sanitizedFullFrames) else { return nil }
        let json: [String: Any] = [
            "schema": "mimo.reference-evidence.v1",
            "identity_scope": "non_person_or_unresolved_subject_fallback",
            "board_mode": board.mode.rawValue,
            "instructions": [
                "No reliable person was detected; identify the dominant user-selected subject conservatively.",
                "Ignore source background, UI, text, logos, and collage decoration.",
                "Do not infer that unrelated objects in different slots are one character.",
            ],
            "reference_count": slots.count,
            "references": metadata,
        ]
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.sortedKeys]),
              let analysisJSON = String(data: data, encoding: .utf8) else { return nil }
        return MimoReferenceProviderPayload(identityBoard: board,
                                            analysisJSON: analysisJSON)
    }

    private struct SanitizedFrame {
        let png: Data
        let removedText: Bool
        let trimmedChrome: Bool
    }

    private func renderSanitizedFullFrame(_ image: CGImage, textRegions: [CGRect])
        -> SanitizedFrame? {
        let fullExtent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let normalizedContent = darkChromeContentRect(image)
        let pixelContent = CGRect(
            x: normalizedContent.minX * CGFloat(image.width),
            y: normalizedContent.minY * CGFloat(image.height),
            width: normalizedContent.width * CGFloat(image.width),
            height: normalizedContent.height * CGFloat(image.height)).integral
            .intersection(fullExtent)
        guard !pixelContent.isNull else { return nil }
        guard let crop = image.cropping(to: pixelContent) else { return nil }
        let longest = max(pixelContent.width, pixelContent.height)
        let scale = min(1, CGFloat(768) / longest)
        let outputWidth = max(8, Int(floor(pixelContent.width * scale)))
        let outputHeight = max(8, Int(floor(pixelContent.height * scale)))
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let contentVision = CGRect(x: normalizedContent.minX,
                                   y: 1 - normalizedContent.maxY,
                                   width: normalizedContent.width,
                                   height: normalizedContent.height)
        guard let base = makeRGBAImage(width: outputWidth, height: outputHeight, draw: { context in
            context.interpolationQuality = .high
            context.draw(crop, in: outputRect)
        }) else { return nil }
        let textRects = textRegions.compactMap { text -> CGRect? in
            let overlap = text.intersection(contentVision)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return nil }
            let x = (overlap.minX - contentVision.minX) / contentVision.width * CGFloat(outputWidth)
            let y = (overlap.minY - contentVision.minY) / contentVision.height * CGFloat(outputHeight)
            let width = overlap.width / contentVision.width * CGFloat(outputWidth)
            let height = overlap.height / contentVision.height * CGFloat(outputHeight)
            let expandX = max(5, width * 0.08)
            let expandY = max(4, height * 0.60)
            return CGRect(x: x - expandX, y: y - expandY,
                          width: width + expandX * 2,
                          height: height + expandY * 2).intersection(outputRect)
        }
        let obscured = obscureText(in: base, regions: textRects)
        guard let png = encodePNG(obscured.image),
              png.count <= configuration.maximumPortraitBytes else { return nil }
        return SanitizedFrame(png: png, removedText: obscured.didObscure,
                              trimmedChrome: normalizedContent != CGRect(x: 0, y: 0,
                                                                         width: 1, height: 1))
    }

    /// Finds only obvious near-black letterbox/app chrome bands. It does not
    /// attempt content-aware cropping, which could silently remove a dark pet
    /// or outfit. Sampling is fixed-size and bounded.
    private func darkChromeContentRect(_ image: CGImage) -> CGRect {
        let sampleWidth = 64
        let sampleHeight = 64
        // This one reads the buffer back after drawing, so it owns the memory
        // explicitly. `&pixels` on a local Array only guaranteed the pointer
        // for the duration of the CGContext call, not for the draw and the
        // scan that follow.
        let byteCount = sampleWidth * sampleHeight * 4
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pixels.initialize(repeating: 0, count: byteCount)
        defer { pixels.deinitialize(count: byteCount); pixels.deallocate() }
        guard let context = CGContext(
            data: pixels, width: sampleWidth, height: sampleHeight,
            bitsPerComponent: 8, bytesPerRow: sampleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: sampleWidth, height: sampleHeight))
        func isDarkBand(_ row: Int) -> Bool {
            var dark = 0
            for x in 0..<sampleWidth {
                let offset = (row * sampleWidth + x) * 4
                if pixels[offset] < 20 && pixels[offset + 1] < 20 && pixels[offset + 2] < 20 {
                    dark += 1
                }
            }
            return Double(dark) / Double(sampleWidth) >= 0.82
        }
        let maximumTrim = Int(Double(sampleHeight) * 0.42)
        var bottom = 0
        while bottom < maximumTrim && isDarkBand(bottom) { bottom += 1 }
        var top = sampleHeight - 1
        while sampleHeight - 1 - top < maximumTrim && top > bottom && isDarkBand(top) { top -= 1 }
        // Ignore tiny changes: they are more likely image content than chrome.
        if bottom < 2 { bottom = 0 }
        if sampleHeight - 1 - top < 2 { top = sampleHeight - 1 }
        return CGRect(x: 0, y: CGFloat(bottom) / CGFloat(sampleHeight),
                      width: 1,
                      height: CGFloat(top - bottom + 1) / CGFloat(sampleHeight))
    }

    private func rounded(_ value: Float) -> Double {
        (Double(value) * 1_000).rounded() / 1_000
    }

    private func paddedCrop(_ person: CGRect, face: CGRect?) -> CGRect {
        let horizontal = person.width * configuration.cropPaddingFraction
        let top = max(person.height * configuration.cropPaddingFraction,
                      face?.height ?? 0)
        let bottom = person.height * configuration.cropPaddingFraction * 0.65
        return CGRect(x: person.minX - horizontal,
                      y: person.minY - bottom,
                      width: person.width + horizontal * 2,
                      height: person.height + bottom + top)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func estimatedPersonBounds(from face: CGRect) -> CGRect {
        let width = face.width * 2.8
        let height = face.height * 5.2
        return CGRect(x: face.midX - width / 2,
                      y: face.maxY - height,
                      width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func view(for yaw: Float?) -> MimoReferenceView {
        guard let yaw else { return .unknown }
        let magnitude = abs(yaw)
        if magnitude < 0.20 { return .frontal }
        if magnitude < 0.72 { return .threeQuarter }
        return .profile
    }

    private func topLeftRect(_ visionRect: CGRect) -> MimoReferenceNormalizedRect {
        MimoReferenceNormalizedRect(x: visionRect.minX,
                                    y: 1 - visionRect.maxY,
                                    width: visionRect.width,
                                    height: visionRect.height)
    }

    /// OCR pixels that overlap the subject cannot be reconstructed locally.
    /// A bounded blur makes them unreadable while retaining underlying color
    /// and silhouette; flat matte rectangles created misleading body holes.
    private struct TextObscuringResult {
        let image: CGImage
        let didObscure: Bool
    }

    private func obscureText(in image: CGImage, regions: [CGRect])
        -> TextObscuringResult {
        guard !regions.isEmpty else {
            return TextObscuringResult(image: image, didObscure: false)
        }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var result = CIImage(cgImage: image)
        let blurred = result.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14])
            .cropped(to: extent)
        for region in regions {
            let clipped = region.integral.intersection(extent)
            guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { continue }
            result = blurred.cropped(to: clipped).composited(over: result).cropped(to: extent)
        }
        // Core Image can be temporarily unavailable in constrained test or
        // login-session environments. Preserve the subject instead of
        // cutting a matte hole through it. `didObscure == false` keeps both
        // the evidence warning and provider metadata honest.
        if let output = ciContext.createCGImage(result, from: extent) {
            return TextObscuringResult(image: output, didObscure: true)
        }
        // A deterministic Core Graphics pixelation is the bounded fallback
        // when Core Image cannot render (observed in login-item/test
        // environments). It destroys glyph shapes without replacing subject
        // pixels with a flat color.
        guard let output = pixelateText(in: image, regions: regions) else {
            return TextObscuringResult(image: image, didObscure: false)
        }
        return TextObscuringResult(image: output, didObscure: true)
    }

    private func pixelateText(in image: CGImage, regions: [CGRect]) -> CGImage? {
        let width = image.width
        let height = image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        return makeRGBAImage(width: width, height: height, draw: { context in
            context.interpolationQuality = .high
            context.draw(image, in: extent)
            for region in regions {
                let clipped = region.integral.intersection(extent)
                guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { continue }
                // CGImage crop coordinates are top-left based, while our text
                // rectangles are in the Core Graphics drawing coordinate space.
                let sourceRect = CGRect(x: clipped.minX,
                                        y: CGFloat(height) - clipped.maxY,
                                        width: clipped.width,
                                        height: clipped.height).integral
                    .intersection(extent)
                guard !sourceRect.isNull, let crop = image.cropping(to: sourceRect) else {
                    continue
                }
                let blockSize = max(8, min(24, Int(clipped.height / 3)))
                let sampleWidth = max(1, Int(clipped.width) / blockSize)
                let sampleHeight = max(1, Int(clipped.height) / blockSize)
                guard let sample = makeRGBAImage(width: sampleWidth,
                                                 height: sampleHeight,
                                                 draw: { sampleContext in
                    sampleContext.interpolationQuality = .medium
                    sampleContext.draw(crop, in: CGRect(x: 0, y: 0,
                                                        width: sampleWidth,
                                                        height: sampleHeight))
                }) else { continue }
                context.interpolationQuality = .none
                context.draw(sample, in: clipped)
            }
        })
    }

    private func makeRGBAImage(width: Int, height: Int,
                               draw: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              width <= 4_096, height <= 4_096 else { return nil }
        // `data: nil` lets CoreGraphics own the backing store for as long as
        // the context and any CGImage derived from it need it. Passing
        // `&pixels` from a local Array was undefined behaviour: that pointer is
        // only guaranteed valid for the duration of the CGContext call itself,
        // while the context keeps writing to it through draw() and makeImage().
        // Nothing here reads the buffer back, so there is no reason to own it.
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        return context.makeImage()
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

// MARK: - Geometry helpers (pure, deterministic and testable)

private func validNormalized(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
    rect.width > 0 && rect.height > 0 && rect.maxX > 0 && rect.maxY > 0 &&
    rect.minX < 1 && rect.minY < 1
}

private func iou(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let union = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    return union > 0 ? intersectionArea / union : 0
}

private func containment(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    let smaller = min(lhs.width * lhs.height, rhs.width * rhs.height)
    return smaller > 0 ? intersection.width * intersection.height / smaller : 0
}

private func overlapRatio(of subject: CGRect, with regions: [CGRect]) -> Float {
    let area = subject.width * subject.height
    guard area > 0 else { return 0 }
    let overlap = regions.reduce(CGFloat(0)) { partial, region in
        let intersection = subject.intersection(region)
        guard !intersection.isNull else { return partial }
        return partial + intersection.width * intersection.height
    }
    return Float(min(1, overlap / area))
}

extension MimoReferenceRejectionReason: Error {}
