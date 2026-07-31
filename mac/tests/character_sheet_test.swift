// sources: character_sheet.swift
import Cocoa

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private let matte: (UInt8, UInt8, UInt8, UInt8) = (241, 236, 226, 255)
private let ink: (UInt8, UInt8, UInt8, UInt8) = (71, 43, 45, 255)
private let nearMatte: (UInt8, UInt8, UInt8, UInt8) = (232, 227, 217, 255)
private let sidecarInk: (UInt8, UInt8, UInt8, UInt8) = (194, 82, 96, 255)

private func paintRect(_ image: inout CharacterSheetRGBAImage,
                       x: Int, y: Int, width: Int, height: Int,
                       color: (UInt8, UInt8, UInt8, UInt8)) {
    for py in y..<(y + height) {
        for px in x..<(x + width) { image.setRGBA(x: px, y: py, color) }
    }
}

private func fixture(emptyStage: Int? = nil,
                     middleFormOverride: (x: Int, width: Int)? = nil,
                     canvasClippedStage: Int? = nil,
                     canvasTouchStage: Int? = nil,
                     mergedBoundary: Int? = nil,
                     sidecarStages: Set<Int> = []) throws -> Data {
    var image = CharacterSheetRGBAImage(width: 1536, height: 1024, fill: matte)
    // Give the inferred matte a little deterministic border variance.
    for x in 0..<image.width {
        let delta = UInt8(x % 3)
        image.setRGBA(x: x, y: 0, (241 + delta, 236 + delta, 226 + delta, 255))
        image.setRGBA(x: x, y: image.height - 1, (241 + delta, 236 + delta, 226 + delta, 255))
    }

    let forms = [
        (x: 170, y: 280, width: 172, height: 600),
        (x: 151, y: 230, width: 210, height: 650),
        (x: 131, y: 180, width: 250, height: 700),
    ]
    for (index, form) in forms.enumerated() where index != emptyStage {
        let panelX = index * 512
        var globalX = panelX + form.x
        var width = form.width
        var y = form.y
        if index == 1, let middleFormOverride {
            // A complete middle form can legitimately extend past the model's
            // requested 512px thirds. There is still clean matte between it
            // and the next form, so this is recoverable rather than clipped.
            globalX = middleFormOverride.x
            width = middleFormOverride.width
        }
        if canvasClippedStage == index {
            if index == 0 { globalX = 5 }
            if index == 1 { y = 5 }
            if index == 2 { globalX = image.width - width - 5 }
        }
        if canvasTouchStage == index {
            if index == 0 { globalX = 0 }
            if index == 1 { y = 0 }
            if index == 2 { globalX = image.width - width }
        }
        paintRect(&image, x: globalX, y: y,
                  width: width, height: form.height, color: ink)
        // A near-background-colored inset must survive because it is not
        // border-connected to the matte.
        paintRect(&image, x: globalX + 20, y: y + 30,
                  width: 20, height: 20, color: nearMatte)
        if sidecarStages.contains(index) {
            // A model may interpret “familiar” as a person plus a small pet.
            // This grounded, disconnected secondary subject must not survive
            // into the desktop sprite.
            paintRect(&image, x: panelX + 35, y: y + form.height - 115,
                      width: 80, height: 115, color: sidecarInk)
        }
        // Provider dust should not expand the character bounds.
        paintRect(&image, x: panelX + 50, y: 50, width: 2, height: 2,
                  color: (130, 40, 170, 255))
    }
    if mergedBoundary == 0 {
        // Join the first two otherwise-valid forms across their entire gutter.
        // No lossless vertical partition exists around x=512.
        paintRect(&image, x: 342, y: 500, width: 322, height: 12, color: ink)
    } else if mergedBoundary == 1 {
        paintRect(&image, x: 873, y: 500, width: 283, height: 12, color: ink)
    }
    return try CharacterSheetProcessor.encodePNG(image)
}

private func containsColor(_ image: CharacterSheetRGBAImage,
                           _ color: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
    for y in 0..<image.height {
        for x in 0..<image.width {
            let pixel = image.rgba(x: x, y: y)
            if pixel == color { return true }
        }
    }
    return false
}

private func singleStageFixture(clipped: Bool = false, touchesEdge: Bool = false,
                                color: (UInt8, UInt8, UInt8, UInt8) = (45, 144, 132, 255)) throws
    -> Data {
    var image = CharacterSheetRGBAImage(width: 1024, height: 1024, fill: matte)
    for x in 0..<image.width {
        let delta = UInt8(x % 3)
        image.setRGBA(x: x, y: 0, (241 + delta, 236 + delta, 226 + delta, 255))
        image.setRGBA(x: x, y: image.height - 1, (241 + delta, 236 + delta, 226 + delta, 255))
    }
    let x = touchesEdge ? 0 : (clipped ? 5 : 300)
    paintRect(&image, x: x, y: 180,
              width: 424, height: 700, color: color)
    paintRect(&image, x: x + 20, y: 210,
              width: 20, height: 20, color: nearMatte)
    paintRect(&image, x: 80, y: 80, width: 2, height: 2,
              color: (130, 40, 170, 255))
    return try CharacterSheetProcessor.encodePNG(image)
}

private func candidateBoardFixture(crossSecondDivider: Bool = false) throws -> Data {
    var image = CharacterSheetRGBAImage(width: 1024, height: 1024, fill: matte)
    for x in 0..<image.width {
        let delta = UInt8(x % 3)
        image.setRGBA(x: x, y: 0, (241 + delta, 236 + delta, 226 + delta, 255))
        image.setRGBA(x: x, y: image.height - 1, (241 + delta, 236 + delta, 226 + delta, 255))
    }
    let forms = [
        (x: 90, width: 160, height: 560),
        (x: 420, width: crossSecondDivider ? 290 : 180, height: 620),
        (x: 770, width: 170, height: 590),
    ]
    for (index, form) in forms.enumerated() {
        let y = 850 - form.height
        paintRect(&image, x: form.x, y: y, width: form.width,
                  height: form.height, color: ink)
        paintRect(&image, x: form.x + 18, y: y + 24, width: 18,
                  height: 18, color: nearMatte)
        paintRect(&image, x: 35 + index * 340, y: 45,
                  width: 2, height: 2, color: (130, 40, 170, 255))
    }
    return try CharacterSheetProcessor.encodePNG(image)
}

private func cellBytes(_ image: CharacterSheetRGBAImage, index: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(512 * 512 * 4)
    for y in 0..<512 {
        let start = (y * image.width + index * 512) * 4
        bytes.append(contentsOf: image.pixels[start..<(start + 512 * 4)])
    }
    return bytes
}

@main
struct CharacterSheetTests {
    static func main() throws {
        var orientation = CharacterSheetRGBAImage(width: 2, height: 2)
        paintRect(&orientation, x: 0, y: 0, width: 2, height: 1,
                  color: (255, 0, 0, 255))
        paintRect(&orientation, x: 0, y: 1, width: 2, height: 1,
                  color: (0, 0, 255, 255))
        let orientationRoundTrip = try CharacterSheetProcessor.decodePNG(
            CharacterSheetProcessor.encodePNG(orientation))
        expect(orientationRoundTrip.rgba(x: 0, y: 0).0 == 255
               && orientationRoundTrip.rgba(x: 0, y: 1).2 == 255,
               "PNG conversion must preserve the processor's top-left row order")

        do {
            _ = try CharacterSheetProcessor.process(pngData: Data("not png".utf8))
            expect(false, "non-PNG payload should fail")
        } catch {
            expect(error as? CharacterSheetProcessingError == .notPNG,
                   "non-PNG should report notPNG")
        }

        let tiny = CharacterSheetRGBAImage(width: 10, height: 8, fill: matte)
        do {
            _ = try CharacterSheetProcessor.process(pngData: CharacterSheetProcessor.encodePNG(tiny))
            expect(false, "wrong dimensions should fail")
        } catch {
            expect(error as? CharacterSheetProcessingError == .invalidDimensions(width: 10, height: 8),
                   "wrong dimensions should include received size")
        }

        let input = try fixture()
        var oversizedHeader = input
        oversizedHeader.replaceSubrange(16..<20, with: [0x00, 0x01, 0x00, 0x00])
        do {
            _ = try CharacterSheetProcessor.process(pngData: oversizedHeader)
            expect(false, "unsafe PNG dimensions should fail before raster decoding")
        } catch {
            expect(error as? CharacterSheetProcessingError == .invalidDimensions(
                width: 65_536, height: 1_024),
                "PNG IHDR dimensions should be preflighted before AppKit decoding")
        }
        let result = try CharacterSheetProcessor.process(pngData: input)
        expect(result.stages.map(\.kind) == [.seed, .bloom, .radiant],
               "stage order must be Seed, Bloom, Radiant")
        expect(result.stagePNGs.count == 3, "processor should expose all three stage PNGs")
        expect(result.baselineY == 500, "all stages should share the documented feet baseline")
        expect(result.quality.resolvedBoundaries == [512, 1024]
               && result.quality.boundaryRecoveries.isEmpty,
               "a well-spaced sheet should retain nominal thirds without recovery warnings")

        let combined = try CharacterSheetProcessor.decodePNG(result.pngData)
        expect(combined.width == 1536 && combined.height == 512,
               "combined sprite sheet must be transparent 1536x512")
        expect(combined.rgba(x: 0, y: 0).3 == 0
               && combined.rgba(x: 511, y: 511).3 == 0,
               "output corners should be transparent")

        let expectedWidths = [172, 210, 250]
        let expectedHeights = [600, 650, 700]
        for index in 0..<3 {
            let stage = result.stages[index]
            expect(stage.sourceBounds.width == expectedWidths[index]
                   && stage.sourceBounds.height == expectedHeights[index],
                   "matte removal should recover stage \(index + 1) bounds and discard dust")
            let bottomEdge = stage.normalizedBounds.y + stage.normalizedBounds.height
            expect(abs(bottomEdge - result.baselineY) <= 1,
                   "stage \(index + 1) feet should align to the shared baseline")
            let decoded = try CharacterSheetProcessor.decodePNG(stage.pngData)
            expect(decoded.width == 512 && decoded.height == 512,
                   "each normalized stage should use a 512px transparent cell")
            expect(containsColor(decoded, nearMatte),
                   "border flood fill must preserve enclosed near-matte character colors")
        }
        expect(result.stages[0].normalizedBounds.height < result.stages[1].normalizedBounds.height
               && result.stages[1].normalizedBounds.height < result.stages[2].normalizedBounds.height,
               "one shared scale must preserve evolution size differences")

        let withoutSidecars = try CharacterSheetProcessor.process(
            pngData: fixture(sidecarStages: [0, 1, 2]))
        expect(withoutSidecars.stages.map(\.sourceBounds.width) == expectedWidths,
               "grounded disconnected companion characters must not expand stage bounds")
        for stage in withoutSidecars.stages {
            let decoded = try CharacterSheetProcessor.decodePNG(stage.pngData)
            expect(!containsColor(decoded, sidecarInk),
                   "grounded disconnected companion characters must be removed locally")
        }

        var legacySheet = try CharacterSheetProcessor.decodePNG(result.pngData)
        for index in 0..<3 {
            paintRect(&legacySheet, x: index * 512 + 20, y: 400,
                      width: 70, height: 80, color: sidecarInk)
        }
        let sanitizedLegacyData = try CharacterSheetProcessor.sanitizeNormalizedSheet(
            pngData: CharacterSheetProcessor.encodePNG(legacySheet))
        let sanitizedLegacy = try CharacterSheetProcessor.decodePNG(sanitizedLegacyData)
        expect(!containsColor(sanitizedLegacy, sidecarInk),
               "existing normalized sheets should be cleaned without another generation")
        let sanitizedCleanData = try CharacterSheetProcessor.sanitizeNormalizedSheet(
            pngData: result.pngData)
        expect(sanitizedCleanData == result.pngData,
               "clean normalized sheets should remain byte-for-byte unchanged")

        let repeated = try CharacterSheetProcessor.process(pngData: input)
        expect(result.pngData == repeated.pngData,
               "processing the same sheet should be byte-for-byte deterministic")

        // Soft matte + bilinear: matte-blended edge pixels survive with a
        // feathered alpha instead of the old binary cut, while the figure's
        // interior stays fully opaque.
        var haloInput = try CharacterSheetProcessor.decodePNG(input)
        var inkMinX = Int.max, inkMinY = Int.max, inkMaxX = -1, inkMaxY = -1
        for y in 0..<haloInput.height {
            for x in 0..<512 {
                let pixel = haloInput.rgba(x: x, y: y)
                guard pixel.0 == ink.0, pixel.1 == ink.1, pixel.2 == ink.2 else { continue }
                inkMinX = min(inkMinX, x); inkMinY = min(inkMinY, y)
                inkMaxX = max(inkMaxX, x); inkMaxY = max(inkMaxY, y)
            }
        }
        expect(inkMaxX >= inkMinX && inkMaxY >= inkMinY, "halo fixture needs the stage-one ink body")
        let blendedHalo: (UInt8, UInt8, UInt8, UInt8) = (223, 218, 206, 255)
        for x in (inkMinX - 1)...(inkMaxX + 1) {
            haloInput.setRGBA(x: x, y: inkMinY - 1, blendedHalo)
            haloInput.setRGBA(x: x, y: inkMaxY + 1, blendedHalo)
        }
        for y in (inkMinY - 1)...(inkMaxY + 1) {
            haloInput.setRGBA(x: inkMinX - 1, y: y, blendedHalo)
            haloInput.setRGBA(x: inkMaxX + 1, y: y, blendedHalo)
        }
        let feathered = try CharacterSheetProcessor.process(
            pngData: CharacterSheetProcessor.encodePNG(haloInput))
        let featheredStage = try CharacterSheetProcessor.decodePNG(feathered.stages[0].pngData)
        var partialAlphaCount = 0
        var opaqueCount = 0
        for y in 0..<featheredStage.height {
            for x in 0..<featheredStage.width {
                let alpha = featheredStage.rgba(x: x, y: y).3
                if alpha > 0 && alpha < 255 { partialAlphaCount += 1 }
                if alpha == 255 { opaqueCount += 1 }
            }
        }
        expect(partialAlphaCount > 0,
               "matte-blended edges should keep a feathered alpha ramp")
        expect(opaqueCount > 0, "figure interiors should stay fully opaque")

        var pale = CharacterSheetRGBAImage(
            width: 64, height: 64, fill: matte)
        let paleInk: (UInt8, UInt8, UInt8, UInt8) = (229, 224, 214, 255)
        let halfBlend: (UInt8, UInt8, UInt8, UInt8) = (235, 230, 220, 255)
        paintRect(&pale, x: 20, y: 20, width: 24, height: 24, color: paleInk)
        for x in 20..<44 {
            pale.setRGBA(x: x, y: 19, halfBlend)
            pale.setRGBA(x: x, y: 44, halfBlend)
        }
        for y in 20..<44 {
            pale.setRGBA(x: 19, y: y, halfBlend)
            pale.setRGBA(x: 44, y: y, halfBlend)
        }
        CharacterSheetProcessor.removeBorderConnectedMatte(from: &pale)
        let recoveredAlpha = Int(pale.rgba(x: 30, y: 19).3)
        expect((105...150).contains(recoveredAlpha),
               "local warm-matte contrast should recover a half-covered pale edge")
        expect(pale.rgba(x: 30, y: 18).3 == 0,
               "flat warm matte outside the pale edge must remain transparent")
        expect(pale.rgba(x: 30, y: 30).3 == 255,
               "the pale clothing interior must remain opaque")

        var edgeTouchingPale = CharacterSheetRGBAImage(
            width: 64, height: 64, fill: matte)
        paintRect(&edgeTouchingPale, x: 1, y: 20, width: 23, height: 24,
                  color: paleInk)
        for y in 20..<44 {
            edgeTouchingPale.setRGBA(x: 0, y: y, halfBlend)
        }
        CharacterSheetProcessor.removeBorderConnectedMatte(
            from: &edgeTouchingPale)
        expect(edgeTouchingPale.rgba(x: 0, y: 30).3 == 0,
               "local recovery must not resurrect pixels on the crop edge")

        var framedPale = CharacterSheetRGBAImage(
            width: 64, height: 64, fill: matte)
        paintRect(&framedPale, x: 20, y: 20, width: 24, height: 24,
                  color: paleInk)
        for x in 16..<48 {
            framedPale.setRGBA(x: x, y: 6, (28, 24, 33, 255))
        }
        CharacterSheetProcessor.removeBorderConnectedMatte(from: &framedPale)
        expect(framedPale.rgba(x: 30, y: 6).3 == 0,
               "a long dark presentation rule near the edge is background")
        expect(framedPale.rgba(x: 30, y: 30).3 == 255,
               "presentation-rule removal must preserve the subject")

        var shortDarkDetail = CharacterSheetRGBAImage(
            width: 64, height: 64, fill: matte)
        for x in 24..<40 {
            shortDarkDetail.setRGBA(x: x, y: 6, (28, 24, 33, 255))
        }
        CharacterSheetProcessor.removeBorderConnectedMatte(
            from: &shortDarkDetail)
        expect(shortDarkDetail.rgba(x: 30, y: 6).3 == 255,
               "a short dark detail must not be mistaken for a frame")

        // Expression generation reuses one normalized stage as its identity
        // reference; extraction must produce a clean single 512px frame.
        let extractedStage = try CharacterSheetProcessor.extractNormalizedStage(
            fromNormalizedSheet: result.pngData, stageIndex: 1)
        let extractedImage = try CharacterSheetProcessor.decodePNG(extractedStage)
        expect(extractedImage.width == 512 && extractedImage.height == 512,
               "an extracted stage should be one 512px cell")
        expect(extractedImage.rgba(x: 0, y: 0).3 == 0,
               "extracted stage corners should stay transparent")
        var extractedForeground = false
        for y in 0..<extractedImage.height where !extractedForeground {
            for x in 0..<extractedImage.width
                where extractedImage.rgba(x: x, y: y).3 == 255 {
                extractedForeground = true
                break
            }
        }
        expect(extractedForeground, "an extracted stage should carry its figure")
        do {
            _ = try CharacterSheetProcessor.extractNormalizedStage(
                fromNormalizedSheet: result.pngData, stageIndex: 3)
            expect(false, "extraction must reject out-of-range stage indices")
        } catch {
            expect(error as? CharacterSheetProcessingError == .emptyStage(3),
                   "extraction should fail with a stage-scoped error")
        }

        let candidateBoard = try CharacterSheetProcessor.processCandidateBoard(
            pngData: candidateBoardFixture())
        expect(candidateBoard.candidatePNGs.count == 3,
               "the Low exploration board should expose exactly three candidates")
        expect(candidateBoard.quality.resolvedBoundaries == [341, 683],
               "a well-spaced candidate board should preserve rounded thirds")
        let candidateStrip = try CharacterSheetProcessor.decodePNG(candidateBoard.pngData)
        expect(candidateStrip.width == 1536 && candidateStrip.height == 512,
               "candidate comparison output should use three transparent 512px cells")
        for png in candidateBoard.candidatePNGs {
            let candidate = try CharacterSheetProcessor.decodePNG(png)
            expect(candidate.width == 512 && candidate.height == 512
                   && candidate.rgba(x: 0, y: 0).3 == 0,
                   "each selectable candidate should be a transparent 512px master")
        }
        let recoveredCandidateBoard = try CharacterSheetProcessor.processCandidateBoard(
            pngData: candidateBoardFixture(crossSecondDivider: true))
        expect(recoveredCandidateBoard.quality.resolvedBoundaries[1] > 683
               && recoveredCandidateBoard.quality.boundaryRecoveries.contains(where: {
                   $0.boundaryIndex == 1 && $0.resolvedX > 683
               }),
               "a complete candidate crossing a nominal divider should recover at its real gutter")

        do {
            _ = try CharacterSheetProcessor.process(pngData: fixture(emptyStage: 1))
            expect(false, "an empty evolution panel should fail")
        } catch {
            expect(error as? CharacterSheetProcessingError == .emptyStage(1),
                   "empty panel should identify its stage")
        }

        let recovered = try CharacterSheetProcessor.process(
            pngData: fixture(middleFormOverride: (x: 820, width: 230)))
        expect(recovered.stages[1].sourceBounds.width == 230,
               "a complete middle form crossing the artificial 1024px divider should be recovered")
        expect(recovered.quality.resolvedBoundaries[1] > 1024,
               "the real right gutter should replace the crossed nominal divider")
        expect(recovered.quality.boundaryRecoveries.contains(where: {
            $0.boundaryIndex == 1 && $0.nominalX == 1024 && $0.resolvedX > 1024
        }), "adaptive boundary recovery should be exposed as structured quality metadata")

        let recoveredAcrossLeft = try CharacterSheetProcessor.process(
            pngData: fixture(middleFormOverride: (x: 500, width: 210)))
        expect(recoveredAcrossLeft.stages[1].sourceBounds.width == 210
               && recoveredAcrossLeft.quality.resolvedBoundaries[0] < 512,
               "a complete middle form crossing the artificial 512px divider should also recover")

        for clippedStage in 0..<3 {
            do {
                _ = try CharacterSheetProcessor.process(
                    pngData: fixture(canvasClippedStage: clippedStage))
                expect(false, "a form touching a physical source-canvas edge should fail")
            } catch {
                expect(error as? CharacterSheetProcessingError == .stageTouchesMargin(clippedStage),
                       "physical canvas clipping should still identify stage \(clippedStage + 1)")
            }
        }

        for nearEdgeStage in 0..<3 {
            let salvaged = try CharacterSheetProcessor.process(
                pngData: fixture(canvasClippedStage: nearEdgeStage),
                allowNearEdgeRecovery: true)
            expect(salvaged.quality.nearEdgeRecoveries.contains(nearEdgeStage),
                   "the explicit salvage pass should disclose a complete near-edge stage")
            do {
                _ = try CharacterSheetProcessor.process(
                    pngData: fixture(canvasTouchStage: nearEdgeStage),
                    allowNearEdgeRecovery: true)
                expect(false, "a character actually touching the source edge must not be salvaged")
            } catch {
                expect(error as? CharacterSheetProcessingError == .stageTouchesMargin(nearEdgeStage),
                       "zero-clearance output must still fail in salvage mode")
            }
        }

        for mergedBoundary in 0..<2 {
            do {
                _ = try CharacterSheetProcessor.process(
                    pngData: fixture(mergedBoundary: mergedBoundary))
                expect(false, "stages joined across a divider should fail")
            } catch {
                expect(error as? CharacterSheetProcessingError == .stagesMerged(mergedBoundary),
                       "an inseparable stage pair should identify boundary \(mergedBoundary + 1)")
            }
        }

        let regenerated = try CharacterSheetProcessor.processSingleStage(
            pngData: singleStageFixture(), kind: .bloom)
        expect(regenerated.stage.kind == .bloom && regenerated.baselineY == 500,
               "single-form processing should preserve the selected evolution kind and baseline")
        let regeneratedPNG = try CharacterSheetProcessor.decodePNG(regenerated.stage.pngData)
        expect(regeneratedPNG.width == 512 && regeneratedPNG.height == 512,
               "a regenerated form should normalize to one transparent 512px cell")
        expect(regeneratedPNG.rgba(x: 0, y: 0).3 == 0,
               "single-form matte removal should produce transparency")
        expect(containsColor(regeneratedPNG, nearMatte),
               "single-form processing should preserve enclosed near-matte details")

        let replacedData = try CharacterSheetProcessor.replaceStage(
            in: result.pngData, kind: .bloom, with: regenerated.stage.pngData)
        let replaced = try CharacterSheetProcessor.decodePNG(replacedData)
        expect(cellBytes(replaced, index: 0) == cellBytes(combined, index: 0),
               "replacing Bloom must not alter the paid Seed frame")
        expect(cellBytes(replaced, index: 1) != cellBytes(combined, index: 1),
               "replacing Bloom should update exactly its frame")
        expect(cellBytes(replaced, index: 2) == cellBytes(combined, index: 2),
               "replacing Bloom must not alter the paid Radiant frame")

        do {
            _ = try CharacterSheetProcessor.processSingleStage(
                pngData: singleStageFixture(clipped: true), kind: .bloom)
            expect(false, "a regenerated form clipped by its physical canvas should fail")
        } catch {
            expect(error as? CharacterSheetProcessingError == .stageTouchesMargin(1),
                   "single-form canvas clipping should preserve the selected stage index")
        }
        let salvagedSingle = try CharacterSheetProcessor.processSingleStage(
            pngData: singleStageFixture(clipped: true), kind: .bloom,
            allowNearEdgeRecovery: true)
        expect(salvagedSingle.recoveredNearEdge,
               "single-stage recovery should use a genuinely more tolerant 1px-safe pass")
        do {
            _ = try CharacterSheetProcessor.processSingleStage(
                pngData: singleStageFixture(touchesEdge: true), kind: .bloom,
                allowNearEdgeRecovery: true)
            expect(false, "a single form touching the canvas cannot be reconstructed locally")
        } catch {
            expect(error as? CharacterSheetProcessingError == .stageTouchesMargin(1),
                   "single-stage salvage must keep zero-clearance rejection")
        }

        let opaqueStage = CharacterSheetRGBAImage(width: 512, height: 512, fill: matte)
        do {
            _ = try CharacterSheetProcessor.replaceStage(
                in: result.pngData,
                kind: .seed,
                with: CharacterSheetProcessor.encodePNG(opaqueStage))
            expect(false, "a raw opaque image must not be inserted as a normalized stage")
        } catch {
            expect(error as? CharacterSheetProcessingError == .normalizedStageHasBackground,
                   "replacement should reject a stage whose background was not removed")
        }

        print("character sheet tests passed")
    }
}
