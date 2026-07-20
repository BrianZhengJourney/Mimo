// Mimo — deterministic processing for GPT Image character sheets.
//
// The provider returns one opaque 1536x1024 PNG containing Seed, Bloom, and
// Radiant in equal thirds. This processor removes the border-connected matte,
// rejects clipped/empty stages, and normalizes all three forms with one scale
// and one feet baseline. No network or model runtime is involved here.

import Cocoa
import Foundation

enum CharacterSheetStageKind: String, CaseIterable, Codable {
    case seed
    case bloom
    case radiant
}

struct CharacterSheetPixelBounds: Equatable, Codable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width - 1 }
    var maxY: Int { y + height - 1 }
    var midX: Double { Double(x) + Double(width) / 2 }
}

struct CharacterSheetProcessedStage {
    let kind: CharacterSheetStageKind
    let pngData: Data
    let sourceBounds: CharacterSheetPixelBounds
    let normalizedBounds: CharacterSheetPixelBounds
}

/// A recoverable deviation from the prompt's nominal 512px thirds. The source
/// image is continuous, so x=512 and x=1024 are layout hints rather than real
/// clipping edges. These values make that recovery observable to callers.
struct CharacterSheetBoundaryRecovery: Equatable, Codable {
    /// 0 separates Seed/Bloom; 1 separates Bloom/Radiant.
    let boundaryIndex: Int
    let nominalX: Int
    let resolvedX: Int
    let leftClearance: Int
    let rightClearance: Int
}

struct CharacterSheetQualityMetadata: Equatable, Codable {
    let resolvedBoundaries: [Int]
    /// Safe transparent pixels on the narrower side of each resolved seam.
    let internalBoundaryClearances: [Int]
    /// Empty for a sheet that already follows the requested thirds cleanly.
    let boundaryRecoveries: [CharacterSheetBoundaryRecovery]
    /// Stages accepted by the explicit no-cost salvage pass with 1...15px of
    /// real outer-canvas clearance. A stage touching 0px is never recoverable.
    let nearEdgeRecoveries: [Int]
}

struct CharacterSheetProcessingResult {
    /// A transparent 1536x512 PNG: Seed, Bloom, and Radiant in 512px cells.
    let pngData: Data
    let stages: [CharacterSheetProcessedStage]
    let scale: Double
    /// Top-left pixel coordinate of the shared bottom edge of every form.
    let baselineY: Int
    let quality: CharacterSheetQualityMetadata

    var stagePNGs: [Data] { stages.map(\.pngData) }
}

struct CharacterSheetSingleStageProcessingResult {
    let stage: CharacterSheetProcessedStage
    let scale: Double
    let baselineY: Int
    let recoveredNearEdge: Bool
}

struct CharacterCandidateBoardProcessingResult {
    /// Transparent comparison strip with three 512×512 candidate cells.
    let pngData: Data
    let candidatePNGs: [Data]
    let quality: CharacterSheetQualityMetadata
}

enum CharacterSheetProcessingError: LocalizedError, Equatable {
    case notPNG
    case unreadableImage
    case invalidDimensions(width: Int, height: Int)
    case invalidCandidateBoardDimensions(width: Int, height: Int)
    case invalidSingleStageDimensions(width: Int, height: Int)
    case invalidNormalizedSheetDimensions(width: Int, height: Int)
    case invalidNormalizedStageDimensions(width: Int, height: Int)
    case emptyStage(Int)
    case stageTooSmall(Int)
    case stageTouchesMargin(Int)
    case stagesMerged(Int)
    case normalizedStageHasBackground
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notPNG:
            return "Character sheet must be a PNG"
        case .unreadableImage:
            return "Character sheet could not be decoded"
        case .invalidDimensions(let width, let height):
            return "Character sheet must be 1536x1024 (received \(width)x\(height))"
        case .invalidCandidateBoardDimensions(let width, let height):
            return "Candidate board must be 1024x1024 (received \(width)x\(height))"
        case .invalidSingleStageDimensions(let width, let height):
            return "A regenerated character form must be 1024x1024 (received \(width)x\(height))"
        case .invalidNormalizedSheetDimensions(let width, let height):
            return "A normalized character sheet must be 1536x512 (received \(width)x\(height))"
        case .invalidNormalizedStageDimensions(let width, let height):
            return "A normalized character form must be 512x512 (received \(width)x\(height))"
        case .emptyStage(let index):
            return "Character sheet stage \(index + 1) is empty"
        case .stageTooSmall(let index):
            return "Character sheet stage \(index + 1) is too small"
        case .stageTouchesMargin(let index):
            return "Character sheet stage \(index + 1) touches the source canvas edge"
        case .stagesMerged(let boundaryIndex):
            return "Character sheet stages \(boundaryIndex + 1) and \(boundaryIndex + 2) overlap or are merged"
        case .normalizedStageHasBackground:
            return "The replacement character form must have a transparent background"
        case .encodingFailed:
            return "Processed character sheet could not be encoded"
        }
    }
}

/// A small RGBA8 image value used internally and by deterministic fixture tests.
struct CharacterSheetRGBAImage: Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        if fill != (0, 0, 0, 0) {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = fill.0
                pixels[index + 1] = fill.1
                pixels[index + 2] = fill.2
                pixels[index + 3] = fill.3
            }
        }
    }

    func rgba(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let index = (y * width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    mutating func setRGBA(x: Int, y: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) {
        let index = (y * width + x) * 4
        pixels[index] = rgba.0
        pixels[index + 1] = rgba.1
        pixels[index + 2] = rgba.2
        pixels[index + 3] = rgba.3
    }
}

enum CharacterSheetProcessor {
    static let inputWidth = 1536
    static let inputHeight = 1024
    static let stageSourceWidth = 512
    static let outputStageSize = 512
    static let outputWidth = 1536
    static let outputHeight = 512
    static let singleStageInputSize = 1024

    /// Source forms must have clear matte around them so a malformed layout is
    /// never silently cropped into a desktop sprite.
    static let requiredSourceMargin = 16
    /// Keep output padding minimal so the figure fills its 512 cell — the
    /// on-screen size comes straight from how much of the cell the art uses.
    /// Must stay ≥ the 8 px transparent border CustomPetStore validates, plus
    /// slack for the feathered edge.
    static let outputSidePadding = 10
    static let outputTopPadding = 10
    static let outputBottomPadding = 12
    /// GPT may miss the requested thirds slightly. Search locally for the real
    /// transparent gutter, while staying conservative about badly merged art.
    static let boundarySearchRadius = 160
    static let minimumBoundaryGutter = 8

    static func process(pngData: Data, allowNearEdgeRecovery: Bool = false) throws
        -> CharacterSheetProcessingResult {
        guard pngData.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw CharacterSheetProcessingError.notPNG
        }
        guard let dimensions = pngPixelDimensions(pngData) else {
            throw CharacterSheetProcessingError.unreadableImage
        }
        guard dimensions.width == inputWidth, dimensions.height == inputHeight else {
            throw CharacterSheetProcessingError.invalidDimensions(
                width: dimensions.width, height: dimensions.height)
        }
        let source = try decodePNG(pngData)
        guard source.width == inputWidth, source.height == inputHeight else {
            throw CharacterSheetProcessingError.invalidDimensions(width: source.width, height: source.height)
        }

        // Clean the continuous canvas before partitioning. Cleaning each fixed
        // third separately made the artificial x=512/1024 dividers behave like
        // physical crop edges and caused complete forms to be rejected.
        var cleanedSource = source
        removeBorderConnectedMatte(from: &cleanedSource)
        removeSmallSpecks(from: &cleanedSource)
        let boundaryResolutions = try resolveInternalBoundaries(
            in: cleanedSource,
            nominalXs: [stageSourceWidth, stageSourceWidth * 2],
            minimumPanelWidth: outputStageSize / 2,
            searchRadius: boundarySearchRadius
        )
        let boundaries = [0] + boundaryResolutions.map(\.resolvedX) + [inputWidth]

        var cleanedStages: [CharacterSheetRGBAImage] = []
        var sourceBounds: [CharacterSheetPixelBounds] = []
        var nearEdgeRecoveries: [Int] = []
        for index in 0..<CharacterSheetStageKind.allCases.count {
            var panel = extractHorizontalRange(cleanedSource,
                                               from: boundaries[index],
                                               to: boundaries[index + 1])
            removeGroundedSidecars(from: &panel)
            let bounds = try validatedBounds(
                of: panel,
                stageIndex: index,
                requireLeftCanvasMargin: index == 0,
                requireRightCanvasMargin: index == CharacterSheetStageKind.allCases.count - 1,
                requiredMargin: allowNearEdgeRecovery ? 1 : requiredSourceMargin
            )
            if allowNearEdgeRecovery,
               usesNearEdgeRecovery(bounds: bounds, imageWidth: panel.width,
                                    imageHeight: panel.height,
                                    requireLeftCanvasMargin: index == 0,
                                    requireRightCanvasMargin: index == CharacterSheetStageKind.allCases.count - 1) {
                nearEdgeRecoveries.append(index)
            }
            cleanedStages.append(panel)
            sourceBounds.append(bounds)
        }

        let largestWidth = sourceBounds.map(\.width).max() ?? 0
        let largestHeight = sourceBounds.map(\.height).max() ?? 0
        guard largestWidth > 0, largestHeight > 0 else {
            throw CharacterSheetProcessingError.emptyStage(0)
        }
        let availableWidth = outputStageSize - outputSidePadding * 2
        let baselineY = outputHeight - outputBottomPadding
        let availableHeight = baselineY - outputTopPadding
        let scale = min(Double(availableWidth) / Double(largestWidth),
                        Double(availableHeight) / Double(largestHeight))

        var combined = CharacterSheetRGBAImage(width: outputWidth, height: outputHeight)
        var processedStages: [CharacterSheetProcessedStage] = []
        for index in cleanedStages.indices {
            let normalized = normalize(cleanedStages[index], bounds: sourceBounds[index],
                                       scale: scale, baselineY: baselineY)
            guard let normalizedBounds = alphaBounds(of: normalized) else {
                throw CharacterSheetProcessingError.emptyStage(index)
            }
            copy(normalized, into: &combined, destinationX: index * outputStageSize)
            let stagePNG = try encodePNG(normalized)
            processedStages.append(CharacterSheetProcessedStage(
                kind: CharacterSheetStageKind.allCases[index],
                pngData: stagePNG,
                sourceBounds: sourceBounds[index],
                normalizedBounds: normalizedBounds
            ))
        }

        let recoveries = boundaryResolutions.compactMap { resolution -> CharacterSheetBoundaryRecovery? in
            let clearance = min(resolution.leftClearance, resolution.rightClearance)
            guard resolution.resolvedX != resolution.nominalX
                    || clearance < requiredSourceMargin else { return nil }
            return CharacterSheetBoundaryRecovery(
                boundaryIndex: resolution.boundaryIndex,
                nominalX: resolution.nominalX,
                resolvedX: resolution.resolvedX,
                leftClearance: resolution.leftClearance,
                rightClearance: resolution.rightClearance
            )
        }
        return CharacterSheetProcessingResult(
            pngData: try encodePNG(combined),
            stages: processedStages,
            scale: scale,
            baselineY: baselineY,
            quality: CharacterSheetQualityMetadata(
                resolvedBoundaries: boundaryResolutions.map(\.resolvedX),
                internalBoundaryClearances: boundaryResolutions.map {
                    min($0.leftClearance, $0.rightClearance)
                },
                boundaryRecoveries: recoveries,
                nearEdgeRecoveries: nearEdgeRecoveries
            )
        )
    }

    /// Extracts the inexpensive three-master exploration board. As with the
    /// production sheet, equal thirds are hints: the real transparent gutters
    /// are resolved on the continuous canvas before any crop is made.
    static func processCandidateBoard(pngData: Data,
                                      allowNearEdgeRecovery: Bool = false) throws
        -> CharacterCandidateBoardProcessingResult {
        guard hasPNGSignature(pngData) else { throw CharacterSheetProcessingError.notPNG }
        guard let dimensions = pngPixelDimensions(pngData) else {
            throw CharacterSheetProcessingError.unreadableImage
        }
        guard dimensions.width == 1024, dimensions.height == 1024 else {
            throw CharacterSheetProcessingError.invalidCandidateBoardDimensions(
                width: dimensions.width, height: dimensions.height)
        }
        var source = try decodePNG(pngData)
        guard source.width == 1024, source.height == 1024 else {
            throw CharacterSheetProcessingError.invalidCandidateBoardDimensions(
                width: source.width, height: source.height)
        }
        removeBorderConnectedMatte(from: &source)
        removeSmallSpecks(from: &source)
        let nominalXs = [
            Int((Double(source.width) / 3).rounded()),
            Int((Double(source.width) * 2 / 3).rounded()),
        ]
        let resolutions = try resolveInternalBoundaries(
            in: source, nominalXs: nominalXs,
            minimumPanelWidth: 170, searchRadius: 120
        )
        let boundaries = [0] + resolutions.map(\.resolvedX) + [source.width]
        var panels: [CharacterSheetRGBAImage] = []
        var bounds: [CharacterSheetPixelBounds] = []
        var nearEdgeRecoveries: [Int] = []
        for index in 0..<3 {
            var panel = extractHorizontalRange(source, from: boundaries[index],
                                               to: boundaries[index + 1])
            removeGroundedSidecars(from: &panel)
            let candidateBounds = try validatedBounds(
                of: panel, stageIndex: index,
                requireLeftCanvasMargin: index == 0,
                requireRightCanvasMargin: index == 2,
                requiredMargin: allowNearEdgeRecovery ? 1 : requiredSourceMargin
            )
            if allowNearEdgeRecovery,
               usesNearEdgeRecovery(bounds: candidateBounds,
                                    imageWidth: panel.width, imageHeight: panel.height,
                                    requireLeftCanvasMargin: index == 0,
                                    requireRightCanvasMargin: index == 2) {
                nearEdgeRecoveries.append(index)
            }
            panels.append(panel)
            bounds.append(candidateBounds)
        }

        let largestWidth = bounds.map(\.width).max() ?? 0
        let largestHeight = bounds.map(\.height).max() ?? 0
        guard largestWidth > 0, largestHeight > 0 else {
            throw CharacterSheetProcessingError.emptyStage(0)
        }
        let availableWidth = outputStageSize - outputSidePadding * 2
        let baselineY = outputHeight - outputBottomPadding
        let availableHeight = baselineY - outputTopPadding
        let scale = min(Double(availableWidth) / Double(largestWidth),
                        Double(availableHeight) / Double(largestHeight))
        var combined = CharacterSheetRGBAImage(width: outputWidth, height: outputHeight)
        var candidates: [Data] = []
        for index in panels.indices {
            let normalized = normalize(panels[index], bounds: bounds[index],
                                       scale: scale, baselineY: baselineY)
            guard alphaBounds(of: normalized) != nil else {
                throw CharacterSheetProcessingError.emptyStage(index)
            }
            copy(normalized, into: &combined, destinationX: index * outputStageSize)
            candidates.append(try encodePNG(normalized))
        }
        let recoveries = resolutions.compactMap { resolution -> CharacterSheetBoundaryRecovery? in
            let clearance = min(resolution.leftClearance, resolution.rightClearance)
            guard resolution.resolvedX != resolution.nominalX
                    || clearance < requiredSourceMargin else { return nil }
            return CharacterSheetBoundaryRecovery(
                boundaryIndex: resolution.boundaryIndex,
                nominalX: resolution.nominalX,
                resolvedX: resolution.resolvedX,
                leftClearance: resolution.leftClearance,
                rightClearance: resolution.rightClearance
            )
        }
        return CharacterCandidateBoardProcessingResult(
            pngData: try encodePNG(combined), candidatePNGs: candidates,
            quality: CharacterSheetQualityMetadata(
                resolvedBoundaries: resolutions.map(\.resolvedX),
                internalBoundaryClearances: resolutions.map {
                    min($0.leftClearance, $0.rightClearance)
                },
                boundaryRecoveries: recoveries,
                nearEdgeRecoveries: nearEdgeRecoveries
            )
        )
    }

    /// Converts one independently regenerated opaque 1024x1024 form into the
    /// same transparent 512x512 runtime contract as a full character sheet.
    static func processSingleStage(pngData: Data,
                                   kind: CharacterSheetStageKind,
                                   allowNearEdgeRecovery: Bool = false) throws
        -> CharacterSheetSingleStageProcessingResult {
        guard hasPNGSignature(pngData) else { throw CharacterSheetProcessingError.notPNG }
        guard let dimensions = pngPixelDimensions(pngData) else {
            throw CharacterSheetProcessingError.unreadableImage
        }
        guard dimensions.width == singleStageInputSize,
              dimensions.height == singleStageInputSize else {
            throw CharacterSheetProcessingError.invalidSingleStageDimensions(
                width: dimensions.width, height: dimensions.height)
        }
        var source = try decodePNG(pngData)
        guard source.width == singleStageInputSize, source.height == singleStageInputSize else {
            throw CharacterSheetProcessingError.invalidSingleStageDimensions(
                width: source.width, height: source.height)
        }
        removeBorderConnectedMatte(from: &source)
        removeSmallSpecks(from: &source)
        removeGroundedSidecars(from: &source)
        let stageIndex = CharacterSheetStageKind.allCases.firstIndex(of: kind) ?? 0
        let bounds = try validatedBounds(of: source,
                                         stageIndex: stageIndex,
                                         requireLeftCanvasMargin: true,
                                         requireRightCanvasMargin: true,
                                         requiredMargin: allowNearEdgeRecovery ? 1 : requiredSourceMargin)
        let recoveredNearEdge = allowNearEdgeRecovery && usesNearEdgeRecovery(
            bounds: bounds, imageWidth: source.width, imageHeight: source.height,
            requireLeftCanvasMargin: true, requireRightCanvasMargin: true)
        let availableWidth = outputStageSize - outputSidePadding * 2
        let baselineY = outputHeight - outputBottomPadding
        let availableHeight = baselineY - outputTopPadding
        let scale = min(Double(availableWidth) / Double(bounds.width),
                        Double(availableHeight) / Double(bounds.height))
        let normalized = normalize(source, bounds: bounds, scale: scale, baselineY: baselineY)
        guard let normalizedBounds = alphaBounds(of: normalized) else {
            throw CharacterSheetProcessingError.emptyStage(stageIndex)
        }
        return CharacterSheetSingleStageProcessingResult(
            stage: CharacterSheetProcessedStage(kind: kind,
                                                 pngData: try encodePNG(normalized),
                                                 sourceBounds: bounds,
                                                 normalizedBounds: normalizedBounds),
            scale: scale,
            baselineY: baselineY,
            recoveredNearEdge: recoveredNearEdge
        )
    }

    /// Removes model-invented grounded companion creatures from an already
    /// normalized runtime sheet. Older v2 assets pass through here on load, so
    /// the cleanup fixes existing pets without another paid generation.
    static func sanitizeNormalizedSheet(pngData: Data) throws -> Data {
        guard hasPNGSignature(pngData) else { throw CharacterSheetProcessingError.notPNG }
        guard let dimensions = pngPixelDimensions(pngData),
              dimensions.width == outputWidth, dimensions.height == outputHeight else {
            let dimensions = pngPixelDimensions(pngData) ?? (0, 0)
            throw CharacterSheetProcessingError.invalidNormalizedSheetDimensions(
                width: dimensions.width, height: dimensions.height)
        }
        let source = try decodePNG(pngData)
        var output = CharacterSheetRGBAImage(width: outputWidth, height: outputHeight)
        var changed = false
        for index in 0..<3 {
            var frame = extractHorizontalRange(source,
                                               from: index * outputStageSize,
                                               to: (index + 1) * outputStageSize)
            if removeGroundedSidecars(from: &frame) > 0 {
                centerForegroundHorizontally(in: &frame)
                changed = true
            }
            copy(frame, into: &output, destinationX: index * outputStageSize)
        }
        return changed ? try encodePNG(output) : pngData
    }

    /// Extracts one normalized 512×512 stage frame from a 1536×512 runtime
    /// sheet. Used as the identity reference for expression-sheet generation.
    static func extractNormalizedStage(fromNormalizedSheet pngData: Data,
                                       stageIndex: Int) throws -> Data {
        guard hasPNGSignature(pngData) else { throw CharacterSheetProcessingError.notPNG }
        guard let dimensions = pngPixelDimensions(pngData),
              dimensions.width == outputWidth, dimensions.height == outputHeight else {
            let dimensions = pngPixelDimensions(pngData) ?? (0, 0)
            throw CharacterSheetProcessingError.invalidNormalizedSheetDimensions(
                width: dimensions.0, height: dimensions.1)
        }
        guard (0..<CharacterSheetStageKind.allCases.count).contains(stageIndex) else {
            throw CharacterSheetProcessingError.emptyStage(stageIndex)
        }
        let sheet = try decodePNG(pngData)
        let frame = extractHorizontalRange(sheet,
                                           from: stageIndex * outputStageSize,
                                           to: (stageIndex + 1) * outputStageSize)
        return try encodePNG(frame)
    }

    /// Replaces exactly one normalized frame without regenerating or touching
    /// the other two paid outputs.
    static func replaceStage(in normalizedSheetPNGData: Data,
                             kind: CharacterSheetStageKind,
                             with normalizedStagePNGData: Data) throws -> Data {
        guard hasPNGSignature(normalizedSheetPNGData),
              hasPNGSignature(normalizedStagePNGData) else {
            throw CharacterSheetProcessingError.notPNG
        }
        guard let sheetDimensions = pngPixelDimensions(normalizedSheetPNGData),
              sheetDimensions.width == outputWidth,
              sheetDimensions.height == outputHeight else {
            let dimensions = pngPixelDimensions(normalizedSheetPNGData) ?? (0, 0)
            throw CharacterSheetProcessingError.invalidNormalizedSheetDimensions(
                width: dimensions.0, height: dimensions.1)
        }
        guard let stageDimensions = pngPixelDimensions(normalizedStagePNGData),
              stageDimensions.width == outputStageSize,
              stageDimensions.height == outputHeight else {
            let dimensions = pngPixelDimensions(normalizedStagePNGData) ?? (0, 0)
            throw CharacterSheetProcessingError.invalidNormalizedStageDimensions(
                width: dimensions.0, height: dimensions.1)
        }
        var sheet = try decodePNG(normalizedSheetPNGData)
        let stage = try decodePNG(normalizedStagePNGData)
        guard sheet.width == outputWidth, sheet.height == outputHeight else {
            throw CharacterSheetProcessingError.invalidNormalizedSheetDimensions(
                width: sheet.width, height: sheet.height)
        }
        guard stage.width == outputStageSize, stage.height == outputHeight else {
            throw CharacterSheetProcessingError.invalidNormalizedStageDimensions(
                width: stage.width, height: stage.height)
        }
        guard hasTransparentBorder(stage) else {
            throw CharacterSheetProcessingError.normalizedStageHasBackground
        }
        let stageIndex = CharacterSheetStageKind.allCases.firstIndex(of: kind) ?? 0
        copy(stage, into: &sheet, destinationX: stageIndex * outputStageSize)
        return try encodePNG(sheet)
    }

    // MARK: - PNG conversion

    static func pngPixelDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24, hasPNGSignature(data),
              data[12] == 0x49, data[13] == 0x48,
              data[14] == 0x44, data[15] == 0x52 else { return nil }
        func value(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = value(at: 16), height = value(at: 20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func decodePNG(_ data: Data) throws -> CharacterSheetRGBAImage {
        guard let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage else {
            throw CharacterSheetProcessingError.unreadableImage
        }
        let width = image.width
        let height = image.height
        var output = CharacterSheetRGBAImage(width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = output.pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { return false }
            // CGImage and the RGBA buffer both use top-first scanlines here.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw CharacterSheetProcessingError.unreadableImage }
        return output
    }

    static func encodePNG(_ image: CharacterSheetRGBAImage) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let data = Data(image.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(width: image.width,
                                    height: image.height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue:
                                        CGBitmapInfo.byteOrder32Big.rawValue
                                        | CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            throw CharacterSheetProcessingError.encodingFailed
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw CharacterSheetProcessingError.encodingFailed
        }
        return png
    }

    // MARK: - Matte and component processing

    private static func hasPNGSignature(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }

    private static func hasTransparentBorder(_ image: CharacterSheetRGBAImage) -> Bool {
        for x in 0..<image.width {
            guard image.rgba(x: x, y: 0).3 == 0,
                  image.rgba(x: x, y: image.height - 1).3 == 0 else { return false }
        }
        for y in 1..<(image.height - 1) {
            guard image.rgba(x: 0, y: y).3 == 0,
                  image.rgba(x: image.width - 1, y: y).3 == 0 else { return false }
        }
        return true
    }

    private static func extractHorizontalRange(_ source: CharacterSheetRGBAImage,
                                               from sourceX: Int,
                                               to sourceEndX: Int) -> CharacterSheetRGBAImage {
        let panelWidth = sourceEndX - sourceX
        var panel = CharacterSheetRGBAImage(width: panelWidth, height: source.height)
        for y in 0..<source.height {
            let inputStart = (y * source.width + sourceX) * 4
            let outputStart = y * panelWidth * 4
            panel.pixels.replaceSubrange(outputStart..<(outputStart + panelWidth * 4),
                                         with: source.pixels[inputStart..<(inputStart + panelWidth * 4)])
        }
        return panel
    }

    private struct BoundaryResolution {
        let boundaryIndex: Int
        let nominalX: Int
        let resolvedX: Int
        let leftClearance: Int
        let rightClearance: Int
    }

    private static func resolveInternalBoundaries(in image: CharacterSheetRGBAImage,
                                                  nominalXs: [Int],
                                                  minimumPanelWidth: Int,
                                                  searchRadius: Int) throws
        -> [BoundaryResolution] {
        var occupiedColumns = [Bool](repeating: false, count: image.width)
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] > 0 {
                occupiedColumns[x] = true
            }
        }

        let halfGutter = minimumBoundaryGutter / 2
        func clearance(at seam: Int, direction: Int) -> Int {
            var x = direction < 0 ? seam - 1 : seam
            var count = 0
            while x >= 0, x < image.width, !occupiedColumns[x] {
                count += 1
                x += direction
            }
            return count
        }

        var output: [BoundaryResolution] = []
        for (boundaryIndex, nominalX) in nominalXs.enumerated() {
            let lower = max(minimumPanelWidth, nominalX - searchRadius)
            let upper = min(image.width - minimumPanelWidth,
                            nominalX + searchRadius)
            var candidates: [(distance: Int, inverseClearance: Int, seam: Int,
                              left: Int, right: Int)] = []
            for seam in lower...upper {
                let left = clearance(at: seam, direction: -1)
                let right = clearance(at: seam, direction: 1)
                guard left >= halfGutter, right >= halfGutter else { continue }
                candidates.append((abs(seam - nominalX), -min(left, right), seam, left, right))
            }
            guard let best = candidates.min(by: {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.inverseClearance != $1.inverseClearance {
                    return $0.inverseClearance < $1.inverseClearance
                }
                return $0.seam < $1.seam
            }) else {
                throw CharacterSheetProcessingError.stagesMerged(boundaryIndex)
            }
            output.append(BoundaryResolution(boundaryIndex: boundaryIndex,
                                             nominalX: nominalX,
                                             resolvedX: best.seam,
                                             leftClearance: best.left,
                                             rightClearance: best.right))
        }
        let boundaries = [0] + output.map(\.resolvedX) + [image.width]
        for index in 0..<(boundaries.count - 1)
            where boundaries[index + 1] - boundaries[index] < minimumPanelWidth {
            throw CharacterSheetProcessingError.stagesMerged(max(0, min(index, nominalXs.count - 1)))
        }
        return output
    }

    static func removeBorderConnectedMatte(from image: inout CharacterSheetRGBAImage) {
        let matte = estimatedMatte(image)
        let threshold = matteThreshold(image, matte: matte)
        let thresholdSquared = threshold * threshold
        let width = image.width
        let height = image.height
        var background = [UInt8](repeating: 0, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * 4 + height * 4)

        func isMatte(_ index: Int) -> Bool {
            let pixel = index * 4
            if image.pixels[pixel + 3] < 16 { return true }
            let dr = Int(image.pixels[pixel]) - matte.0
            let dg = Int(image.pixels[pixel + 1]) - matte.1
            let db = Int(image.pixels[pixel + 2]) - matte.2
            return dr * dr + dg * dg + db * db <= thresholdSquared
        }
        func seed(_ index: Int) {
            guard background[index] == 0, isMatte(index) else { return }
            background[index] = 1
            queue.append(index)
        }

        for x in 0..<width {
            seed(x)
            seed((height - 1) * width + x)
        }
        for y in 0..<height {
            seed(y * width)
            seed(y * width + width - 1)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            if x > 0 { seed(index - 1) }
            if x + 1 < width { seed(index + 1) }
            if y > 0 { seed(index - width) }
            if y + 1 < height { seed(index + width) }
        }

        // Foreground pixels touching the background get a feathered alpha ramp
        // based on how matte-blended their color is, so raster portraits keep
        // anti-aliased edges instead of a hard binary cut. Interior pixels stay
        // fully opaque, which preserves crisp pixel-style art.
        var boundaryBand = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) where background[index] == 0 {
            let x = index % width
            let y = index / width
            var nearBackground = false
            outer: for dy in -2...2 {
                let ny = y + dy
                guard ny >= 0, ny < height else { nearBackground = true; break }
                for dx in -2...2 {
                    let nx = x + dx
                    guard nx >= 0, nx < width else { nearBackground = true; break outer }
                    if background[ny * width + nx] == 1 { nearBackground = true; break outer }
                }
            }
            if nearBackground { boundaryBand[index] = 1 }
        }

        for index in 0..<(width * height) {
            let pixel = index * 4
            if background[index] == 1 || image.pixels[pixel + 3] < 16 {
                image.pixels[pixel] = 0
                image.pixels[pixel + 1] = 0
                image.pixels[pixel + 2] = 0
                image.pixels[pixel + 3] = 0
            } else if boundaryBand[index] == 1 {
                let dr = Int(image.pixels[pixel]) - matte.0
                let dg = Int(image.pixels[pixel + 1]) - matte.1
                let db = Int(image.pixels[pixel + 2]) - matte.2
                let distance = Double(dr * dr + dg * dg + db * db).squareRoot()
                // Ramp from transparent at the matte threshold up to opaque at
                // 3× the threshold, smoothstepped for gentle edges.
                let t = max(0.0, min(1.0, (distance - Double(threshold)) / (2.0 * Double(threshold))))
                let smooth = t * t * (3.0 - 2.0 * t)
                let alpha = UInt8(max(0.0, min(255.0, (smooth * 255.0).rounded())))
                // Buffers are premultiplied; scale color with the new alpha.
                image.pixels[pixel] = UInt8(Int(image.pixels[pixel]) * Int(alpha) / 255)
                image.pixels[pixel + 1] = UInt8(Int(image.pixels[pixel + 1]) * Int(alpha) / 255)
                image.pixels[pixel + 2] = UInt8(Int(image.pixels[pixel + 2]) * Int(alpha) / 255)
                image.pixels[pixel + 3] = alpha
            } else {
                image.pixels[pixel + 3] = 255
            }
        }
    }

    private static func estimatedMatte(_ image: CharacterSheetRGBAImage) -> (Int, Int, Int) {
        var red: [UInt8] = []
        var green: [UInt8] = []
        var blue: [UInt8] = []
        red.reserveCapacity((image.width + image.height) * 2)
        green.reserveCapacity(red.capacity)
        blue.reserveCapacity(red.capacity)

        func sample(x: Int, y: Int) {
            let pixel = (y * image.width + x) * 4
            guard image.pixels[pixel + 3] >= 16 else { return }
            red.append(image.pixels[pixel])
            green.append(image.pixels[pixel + 1])
            blue.append(image.pixels[pixel + 2])
        }
        for x in 0..<image.width {
            sample(x: x, y: 0)
            sample(x: x, y: image.height - 1)
        }
        for y in 1..<(image.height - 1) {
            sample(x: 0, y: y)
            sample(x: image.width - 1, y: y)
        }
        guard !red.isEmpty else { return (0, 0, 0) }
        red.sort(); green.sort(); blue.sort()
        let middle = red.count / 2
        return (Int(red[middle]), Int(green[middle]), Int(blue[middle]))
    }

    private static func matteThreshold(_ image: CharacterSheetRGBAImage,
                                       matte: (Int, Int, Int)) -> Int {
        var distances: [Int] = []
        distances.reserveCapacity((image.width + image.height) * 2)
        func sample(x: Int, y: Int) {
            let pixel = (y * image.width + x) * 4
            guard image.pixels[pixel + 3] >= 16 else { return }
            let dr = Int(image.pixels[pixel]) - matte.0
            let dg = Int(image.pixels[pixel + 1]) - matte.1
            let db = Int(image.pixels[pixel + 2]) - matte.2
            distances.append(Int(Double(dr * dr + dg * dg + db * db).squareRoot()))
        }
        for x in 0..<image.width {
            sample(x: x, y: 0)
            sample(x: x, y: image.height - 1)
        }
        for y in 1..<(image.height - 1) {
            sample(x: 0, y: y)
            sample(x: image.width - 1, y: y)
        }
        guard !distances.isEmpty else { return 24 }
        distances.sort()
        let percentile = distances[min(distances.count - 1, distances.count * 9 / 10)]
        return min(44, max(18, percentile + 10))
    }

    private struct AlphaComponent {
        let pixels: [Int]
        let bounds: CharacterSheetPixelBounds
    }

    private static func alphaComponents(in image: CharacterSheetRGBAImage) -> [AlphaComponent] {
        let width = image.width
        let height = image.height
        var labels = [Int](repeating: -1, count: width * height)
        var components: [AlphaComponent] = []
        var queue: [Int] = []

        for start in 0..<(width * height) {
            guard labels[start] == -1, image.pixels[start * 4 + 3] > 0 else { continue }
            let label = components.count
            labels[start] = label
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var component: [Int] = []
            var minimumX = width, minimumY = height, maximumX = 0, maximumY = 0
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                component.append(index)
                let x = index % width
                let y = index / width
                minimumX = min(minimumX, x); maximumX = max(maximumX, x)
                minimumY = min(minimumY, y); maximumY = max(maximumY, y)
                for oy in -1...1 {
                    for ox in -1...1 where ox != 0 || oy != 0 {
                        let nx = x + ox, ny = y + oy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        guard labels[neighbor] == -1,
                              image.pixels[neighbor * 4 + 3] > 0 else { continue }
                        labels[neighbor] = label
                        queue.append(neighbor)
                    }
                }
            }
            components.append(AlphaComponent(
                pixels: component,
                bounds: CharacterSheetPixelBounds(
                    x: minimumX, y: minimumY,
                    width: maximumX - minimumX + 1,
                    height: maximumY - minimumY + 1)))
        }
        return components
    }

    static func removeSmallSpecks(from image: inout CharacterSheetRGBAImage) {
        let components = alphaComponents(in: image)
        guard let largest = components.map({ $0.pixels.count }).max(), largest > 0 else { return }
        let minimumArea = max(16, min(256, largest / 500))
        for component in components where component.pixels.count < minimumArea {
            for index in component.pixels {
                let pixel = index * 4
                image.pixels[pixel] = 0
                image.pixels[pixel + 1] = 0
                image.pixels[pixel + 2] = 0
                image.pixels[pixel + 3] = 0
            }
        }
    }

    /// A generated human familiar can be misread as “person plus familiar”,
    /// producing a second little creature beside the feet. Keep the largest
    /// character and remove only substantial subordinate components that are
    /// entirely in its lower half and share its ground line. Detached wings,
    /// sparkles, hair flourishes, and tiny edge pixels remain untouched.
    @discardableResult
    private static func removeGroundedSidecars(from image: inout CharacterSheetRGBAImage) -> Int {
        let components = alphaComponents(in: image)
        guard let main = components.max(by: { $0.pixels.count < $1.pixels.count }),
              main.pixels.count > 0 else { return 0 }
        let mainBottom = main.bounds.y + main.bounds.height
        let minimumArea = max(384, main.pixels.count / 20)
        let lowerHalf = main.bounds.y + main.bounds.height * 45 / 100
        let groundTolerance = max(12, main.bounds.height * 8 / 100)
        var removed = 0
        for component in components where component.pixels != main.pixels {
            let bounds = component.bounds
            let bottom = bounds.y + bounds.height
            guard component.pixels.count >= minimumArea,
                  bounds.y >= lowerHalf,
                  bounds.height * 100 <= main.bounds.height * 55,
                  abs(bottom - mainBottom) <= groundTolerance else { continue }
            for index in component.pixels {
                let pixel = index * 4
                image.pixels[pixel] = 0
                image.pixels[pixel + 1] = 0
                image.pixels[pixel + 2] = 0
                image.pixels[pixel + 3] = 0
            }
            removed += 1
        }
        return removed
    }

    private static func centerForegroundHorizontally(in image: inout CharacterSheetRGBAImage) {
        guard let bounds = alphaBounds(of: image) else { return }
        let targetX = (image.width - bounds.width) / 2
        let shift = targetX - bounds.x
        guard shift != 0 else { return }
        var centered = CharacterSheetRGBAImage(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] > 0 {
                let destinationX = x + shift
                guard destinationX >= 0, destinationX < image.width else { continue }
                let sourcePixel = (y * image.width + x) * 4
                let destinationPixel = (y * image.width + destinationX) * 4
                centered.pixels[destinationPixel..<(destinationPixel + 4)] =
                    image.pixels[sourcePixel..<(sourcePixel + 4)]
            }
        }
        image = centered
    }

    private static func validatedBounds(of image: CharacterSheetRGBAImage,
                                        stageIndex: Int,
                                        requireLeftCanvasMargin: Bool,
                                        requireRightCanvasMargin: Bool,
                                        requiredMargin: Int) throws
        -> CharacterSheetPixelBounds {
        guard let bounds = alphaBounds(of: image) else {
            throw CharacterSheetProcessingError.emptyStage(stageIndex)
        }
        let opaquePixels = stride(from: 3, to: image.pixels.count, by: 4)
            .reduce(into: 0) { count, index in if image.pixels[index] > 0 { count += 1 } }
        guard bounds.width >= 24, bounds.height >= 24, opaquePixels >= 384 else {
            throw CharacterSheetProcessingError.stageTooSmall(stageIndex)
        }
        let rightMargin = image.width - (bounds.x + bounds.width)
        let bottomMargin = image.height - (bounds.y + bounds.height)
        guard (!requireLeftCanvasMargin || bounds.x >= requiredMargin),
              bounds.y >= requiredMargin,
              (!requireRightCanvasMargin || rightMargin >= requiredMargin),
              bottomMargin >= requiredMargin else {
            throw CharacterSheetProcessingError.stageTouchesMargin(stageIndex)
        }
        return bounds
    }

    private static func usesNearEdgeRecovery(bounds: CharacterSheetPixelBounds,
                                             imageWidth: Int, imageHeight: Int,
                                             requireLeftCanvasMargin: Bool,
                                             requireRightCanvasMargin: Bool) -> Bool {
        let right = imageWidth - (bounds.x + bounds.width)
        let bottom = imageHeight - (bounds.y + bounds.height)
        return (requireLeftCanvasMargin && bounds.x < requiredSourceMargin)
            || bounds.y < requiredSourceMargin
            || (requireRightCanvasMargin && right < requiredSourceMargin)
            || bottom < requiredSourceMargin
    }

    // MARK: - Shared normalization

    private static func normalize(_ source: CharacterSheetRGBAImage,
                                  bounds: CharacterSheetPixelBounds,
                                  scale: Double,
                                  baselineY: Int) -> CharacterSheetRGBAImage {
        var output = CharacterSheetRGBAImage(width: outputStageSize, height: outputHeight)
        let xOffset = Double(outputStageSize) / 2 - bounds.midX * scale
        let sourceBottomEdge = Double(bounds.y + bounds.height)
        let yOffset = Double(baselineY) - sourceBottomEdge * scale

        let minimumX = max(0, Int(floor(xOffset + Double(bounds.x) * scale)))
        let maximumX = min(output.width - 1,
                           Int(ceil(xOffset + Double(bounds.x + bounds.width) * scale)) - 1)
        let minimumY = max(0, Int(floor(yOffset + Double(bounds.y) * scale)))
        let maximumY = min(output.height - 1,
                           Int(ceil(yOffset + Double(bounds.y + bounds.height) * scale)) - 1)
        guard minimumX <= maximumX, minimumY <= maximumY else { return output }

        // Bilinear sampling over the premultiplied buffer — a weighted average
        // of premultiplied RGBA is compositing-correct and keeps raster
        // portraits smooth (nearest-neighbor aliased them badly).
        func channel(_ sx: Int, _ sy: Int, _ offset: Int) -> Double {
            guard sx >= 0, sx < source.width, sy >= 0, sy < source.height else { return 0 }
            return Double(source.pixels[(sy * source.width + sx) * 4 + offset])
        }
        for y in minimumY...maximumY {
            let sourceYCenter = (Double(y) + 0.5 - yOffset) / scale - 0.5
            let y0 = Int(floor(sourceYCenter))
            let fy = sourceYCenter - Double(y0)
            for x in minimumX...maximumX {
                let sourceXCenter = (Double(x) + 0.5 - xOffset) / scale - 0.5
                let x0 = Int(floor(sourceXCenter))
                let fx = sourceXCenter - Double(x0)
                let w00 = (1 - fx) * (1 - fy)
                let w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy
                let w11 = fx * fy
                var rgba = [0.0, 0.0, 0.0, 0.0]
                for offset in 0..<4 {
                    rgba[offset] = channel(x0, y0, offset) * w00
                        + channel(x0 + 1, y0, offset) * w10
                        + channel(x0, y0 + 1, offset) * w01
                        + channel(x0 + 1, y0 + 1, offset) * w11
                }
                let alpha = UInt8(max(0.0, min(255.0, rgba[3].rounded())))
                guard alpha > 0 else { continue }
                let outputIndex = (y * output.width + x) * 4
                output.pixels[outputIndex] = UInt8(max(0.0, min(255.0, rgba[0].rounded())))
                output.pixels[outputIndex + 1] = UInt8(max(0.0, min(255.0, rgba[1].rounded())))
                output.pixels[outputIndex + 2] = UInt8(max(0.0, min(255.0, rgba[2].rounded())))
                output.pixels[outputIndex + 3] = alpha
            }
        }
        return output
    }

    static func alphaBounds(of image: CharacterSheetRGBAImage) -> CharacterSheetPixelBounds? {
        var minimumX = image.width
        var minimumY = image.height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixels[(y * image.width + x) * 4 + 3] > 0 {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CharacterSheetPixelBounds(x: minimumX, y: minimumY,
                                         width: maximumX - minimumX + 1,
                                         height: maximumY - minimumY + 1)
    }

    private static func copy(_ source: CharacterSheetRGBAImage,
                             into destination: inout CharacterSheetRGBAImage,
                             destinationX: Int) {
        for y in 0..<source.height {
            let sourceStart = y * source.width * 4
            let destinationStart = (y * destination.width + destinationX) * 4
            destination.pixels.replaceSubrange(destinationStart..<(destinationStart + source.width * 4),
                                                with: source.pixels[sourceStart..<(sourceStart + source.width * 4)])
        }
    }
}
