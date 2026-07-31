// sources: character_sheet.swift action_sheet.swift
import Foundation

@main
struct ActionSheetTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    /// Builds an R×C sheet where each cell holds one opaque rect, given in cell
    /// coordinates with y measured down from the cell's top.
    static func makeSheet(cell: Int, layout: ActionSheetLayout,
                          blobs: [CharacterSheetPixelBounds],
                          matte: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0))
        -> CharacterSheetRGBAImage {
        var image = CharacterSheetRGBAImage(width: cell * layout.columns,
                                            height: cell * layout.rows,
                                            fill: matte)
        for (index, blob) in blobs.enumerated() {
            let column = index % layout.columns, row = index / layout.columns
            for y in blob.y..<(blob.y + blob.height) {
                for x in blob.x..<(blob.x + blob.width) {
                    let px = column * cell + x, py = row * cell + y
                    guard px < image.width, py < image.height else { continue }
                    let offset = (py * image.width + px) * 4
                    image.pixels[offset] = 220
                    image.pixels[offset + 1] = 120
                    image.pixels[offset + 2] = 90
                    image.pixels[offset + 3] = 255
                }
            }
        }
        return image
    }

    static func png(_ image: CharacterSheetRGBAImage) -> Data {
        try! CharacterSheetProcessor.encodePNG(image)
    }

    static func bounds(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CharacterSheetPixelBounds {
        CharacterSheetPixelBounds(x: x, y: y, width: w, height: h)
    }

    /// Sixteen cells — the production 4x4 layout — each with a subject of a
    /// different height and position, which is exactly what different frames
    /// of one character look like.
    static func sixteenFrames(cell: Int = 128) -> CharacterSheetRGBAImage {
        let heights = [70, 68, 72, 66, 74, 69, 71, 67, 73, 70, 68, 72, 66, 74, 69, 71]
        let blobs = heights.enumerated().map { index, height in
            bounds(40 + (index % 4) * 4, cell - 20 - height, 30, height)
        }
        return makeSheet(cell: cell, layout: .fourByFour, blobs: blobs)
    }

    // MARK: - Slicing

    static func testSlicesEveryCell() throws {
        let result = try ActionSheetProcessor.process(pngData: png(sixteenFrames()))
        expect(result.frames.count == 16, "4x4 yields sixteen frames, got \(result.frames.count)")
        expect(result.sourceCells.count == 16, "and sixteen source cells for the gate to score")
        expect(result.frames.map(\.index) == Array(0..<16), "frames keep grid order")
    }

    static func testStripGeometryMatchesTheRuntimeContract() throws {
        let result = try ActionSheetProcessor.process(pngData: png(sixteenFrames()))
        let decoded = try CharacterSheetProcessor.decodePNG(result.pngData)
        expect(decoded.height == result.cellSize, "strip is one cell tall")
        expect(decoded.width == result.cellSize * 16, "strip is sixteen cells wide")
    }

    /// The rule this file exists for. Every frame must share one scale and one
    /// baseline; fitting each pose to its own cell makes the character change
    /// size and hop vertically, and a walk cycle built from that jitters.
    static func testAllFramesShareOneScaleAndBaseline() throws {
        let result = try ActionSheetProcessor.process(pngData: png(sixteenFrames()))
        let decoded = try CharacterSheetProcessor.decodePNG(result.pngData)

        let baselines = Set(result.frames.map(\.anchorY))
        expect(baselines.count == 1,
               "every frame must land on one baseline, got \(baselines.sorted())")

        // Subject heights differ in the source by design; after a shared scale
        // their ratios must be preserved rather than flattened to one height.
        var renderedHeights: [Int] = []
        for index in 0..<16 {
            let frame = ActionSheetProcessor.crop(decoded,
                                                  x: index * result.cellSize, y: 0,
                                                  width: result.cellSize, height: result.cellSize)
            guard let bounds = CharacterSheetProcessor.alphaBounds(of: frame) else {
                preconditionFailure("frame \(index) came out empty")
            }
            renderedHeights.append(bounds.height)
            expect(bounds.maxY <= result.cellSize - 1, "frame \(index) stays inside its cell")
        }
        expect(Set(renderedHeights).count > 1,
               "a shared scale must preserve pose height differences, not flatten them")

        // Source heights ran 66…74, a 12% spread. It must survive scaling.
        let tallest = renderedHeights.max()!, shortest = renderedHeights.min()!
        let spread = Double(tallest - shortest) / Double(tallest)
        expect(spread > 0.05 && spread < 0.2,
               "relative pose heights should be preserved, got \(spread)")
    }

    static func testFeetLandOnTheBaseline() throws {
        let result = try ActionSheetProcessor.process(pngData: png(sixteenFrames()))
        let decoded = try CharacterSheetProcessor.decodePNG(result.pngData)
        for frame in result.frames {
            let cell = ActionSheetProcessor.crop(decoded,
                                                 x: frame.index * result.cellSize, y: 0,
                                                 width: result.cellSize, height: result.cellSize)
            guard let bounds = CharacterSheetProcessor.alphaBounds(of: cell) else {
                preconditionFailure("frame \(frame.index) empty")
            }
            expect(abs(bounds.maxY - (frame.anchorY - 1)) <= 2,
                   "frame \(frame.index) feet should sit on the reported baseline "
                   + "(bounds \(bounds.maxY), anchor \(frame.anchorY))")
        }
    }

    /// The bug the user reported as "someone's feet above her head": a
    /// neighbouring panel's overflow crosses the grid line, the sliced cell
    /// keeps it, its bounds inflate, and the frame renders a shrunken subject
    /// with stray shoes floating on top. Edge-touching runts must be removed
    /// before bounds are taken.
    static func testNeighbourOverflowIsRemovedFromTheCell() throws {
        let cell = 128
        let heights = Array(repeating: 70, count: 16)
        var sheet = makeSheet(cell: cell, layout: .fourByFour,
                              blobs: heights.enumerated().map { index, height in
                                  bounds(40 + (index % 4) * 4, cell - 20 - height, 30, height)
                              })
        // Paint "feet" hanging from the top edge of cell 5 (row 1, column 1):
        // a small blob that touches y = 0 of that cell.
        let cellX = 1 * cell, cellY = 1 * cell
        for y in 0..<14 {
            for x in 0..<22 {
                let offset = ((cellY + y) * sheet.width + cellX + 50 + x) * 4
                sheet.pixels[offset] = 120; sheet.pixels[offset + 1] = 90
                sheet.pixels[offset + 2] = 60; sheet.pixels[offset + 3] = 255
            }
        }
        let result = try ActionSheetProcessor.process(pngData: png(sheet))
        // With the intruder removed, cell 5's subject bounds match everyone
        // else's; if it survived, the bounds would start at the cell top.
        expect(result.frames[5].bounds.height == result.frames[4].bounds.height,
               "the intruder must not inflate the subject bounds, got "
               + "\(result.frames[5].bounds.height) vs \(result.frames[4].bounds.height)")
    }

    /// A subject drawn against the grid line was amputated by it — the toes
    /// live in the next panel. Nothing downstream can restore them, so the
    /// sheet must be rejected with the edge named. Unlike the identity gate,
    /// a reroll on this signal is a real defect worth paying to fix.
    static func testSubjectCutByThePanelEdgeIsRejected() {
        let cell = 128
        var blobs = (0..<16).map { index in
            bounds(40 + (index % 4) * 4, cell - 20 - 70, 30, 70)
        }
        // Cell 9's subject runs all the way into the bottom edge.
        blobs[9] = bounds(44, cell - 90, 30, 90)
        let sheet = makeSheet(cell: cell, layout: .fourByFour, blobs: blobs)
        do {
            _ = try ActionSheetProcessor.process(pngData: png(sheet))
            preconditionFailure("a subject cut by the panel edge must fail the sheet")
        } catch let error as ActionSheetError {
            guard case .subjectClipped(let index, let edge) = error else {
                preconditionFailure("expected subjectClipped, got \(error)")
            }
            expect(index == 9 && edge == "bottom", "the error names the cell and edge, got \(index)/\(edge)")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// The first retained tennis batch kept the complete racket on the canvas,
    /// but it crossed the implied 512px boundary into empty space before the
    /// next pose. The boundary was wrong; the art was not cropped. A clear
    /// inter-pose gutter must recover that frame without a paid reroll.
    static func testUnframedHorizontalFamilyRegistersTransparentGutters() throws {
        let width = 384, height = 128
        var sheet = CharacterSheetRGBAImage(
            width: width, height: height, fill: (241, 236, 226, 255))
        for rectangle in [
            bounds(36, 26, 119, 82),   // crosses the implied x=128 boundary
            bounds(178, 28, 62, 80),
            bounds(292, 24, 58, 84),
        ] {
            for y in rectangle.y..<(rectangle.y + rectangle.height) {
                for x in rectangle.x..<(rectangle.x + rectangle.width) {
                    sheet.setRGBA(x: x, y: y, (70, 46, 38, 255))
                }
            }
        }
        let result = try ActionSheetProcessor.process(
            pngData: png(sheet),
            layout: ActionSheetLayout(rows: 1, columns: 3),
            outputCellSize: 128)
        expect(result.frames.count == 3,
               "three recoverable poses remain three registered frames")
        expect(result.frames[0].bounds.width == 119,
               "the complete cross-boundary racket/body silhouette is retained")
        expect(result.sourceCells.allSatisfy {
            ActionSheetProcessor.clippedEdge(of: $0) == nil
        }, "every recovered pose sits clear of its measured gutter")
    }

    static func testSparseLargePanelEdgeContactIsNotClipping() {
        var cell = CharacterSheetRGBAImage(width: 500, height: 1000)
        // A safely contained body plus eighteen antialiased hair pixels at the
        // side, matching the real sleep batch that was falsely rejected.
        for y in 400..<700 {
            for x in 80..<360 {
                cell.setRGBA(x: x, y: y, (220, 120, 90, 255))
            }
        }
        for y in 470..<488 {
            cell.setRGBA(x: 0, y: y, (80, 50, 40, 255))
        }
        expect(ActionSheetProcessor.clippedEdge(of: cell) == nil,
               "sparse contact in a large panel is not a cropped subject")
    }

    /// The second-pass walk result drew the last row through the canvas's
    /// bottom frame, leaving four waist-up sprites. Framed sheets used to
    /// exempt bottom contact because older prompts treated the bar as a floor;
    /// the current 96px safety-margin contract makes every such contact a crop.
    static func testFramedBottomContactIsRejected() {
        let cell = 128
        let layout = ActionSheetLayout(rows: 2, columns: 2)
        var sheet = CharacterSheetRGBAImage(
            width: cell * 2, height: cell * 2, fill: (241, 236, 226, 255))
        // Six-pixel outer and internal #1A1A2E frame bands.
        for y in 0..<sheet.height {
            for x in 0..<sheet.width {
                if x < 6 || x >= sheet.width - 6 || abs(x - cell) < 3
                    || y < 6 || y >= sheet.height - 6 || abs(y - cell) < 3 {
                    let offset = (y * sheet.width + x) * 4
                    sheet.pixels[offset] = 26; sheet.pixels[offset + 1] = 26
                    sheet.pixels[offset + 2] = 46; sheet.pixels[offset + 3] = 255
                }
            }
        }
        // Three safe figures and one last-row figure disappearing into the
        // bottom band, as in the real rejected M13–M16 output.
        let figures = [
            bounds(38, 30, 42, 70), bounds(cell + 38, 30, 42, 70),
            bounds(38, cell + 20, 42, 80), bounds(cell + 38, cell + 20, 42, 124),
        ]
        for figure in figures {
            for y in figure.y..<min(sheet.height, figure.y + figure.height) {
                for x in figure.x..<min(sheet.width, figure.x + figure.width) {
                    let offset = (y * sheet.width + x) * 4
                    sheet.pixels[offset] = 220; sheet.pixels[offset + 1] = 120
                    sheet.pixels[offset + 2] = 90; sheet.pixels[offset + 3] = 255
                }
            }
        }
        do {
            _ = try ActionSheetProcessor.process(pngData: png(sheet), layout: layout)
            preconditionFailure("a figure cut by a framed canvas bottom must be rejected")
        } catch let error as ActionSheetError {
            guard case .subjectClipped(let index, let edge) = error else {
                preconditionFailure("expected subjectClipped, got \(error)")
            }
            expect(index == 3 && edge == "bottom",
                   "the last framed cell is rejected at bottom, got \(index)/\(edge)")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// GPT Image sometimes renders one separator as two dark strokes with a
    /// narrow light gap. Treat that pair as one frame band; falling back to
    /// uniform 512px slicing leaves the presentation border in the cell and
    /// falsely reports a safely padded subject as bottom-clipped.
    static func testSplitStrokePanelBordersAreMerged() throws {
        let cell = 128
        let layout = ActionSheetLayout(rows: 1, columns: 3)
        var sheet = makeSheet(
            cell: cell, layout: layout,
            blobs: [
                bounds(35, 36, 58, 62),
                bounds(34, 40, 60, 58),
                // Close to the separator, but still wholly inside it. The
                // registration crop must not amputate these leading pixels.
                bounds(8, 38, 56, 60),
            ],
            matte: (239, 234, 224, 255))

        func paintColumn(_ x: Int) {
            for y in 0..<sheet.height {
                sheet.setRGBA(x: x, y: y, (48, 34, 74, 255))
            }
        }
        func paintRow(_ y: Int) {
            for x in 0..<sheet.width {
                sheet.setRGBA(x: x, y: y, (48, 34, 74, 255))
            }
        }
        // Leave a thin white presentation rim around the outer frame, as the
        // real wall batch does.
        for inset in 2..<6 {
            paintRow(inset); paintRow(sheet.height - 1 - inset)
            paintColumn(inset); paintColumn(sheet.width - 1 - inset)
        }
        for boundary in [cell, cell * 2] {
            for offset in -5 ... -3 { paintColumn(boundary + offset) }
            for offset in 1...3 { paintColumn(boundary + offset) }
        }

        let data = png(sheet)
        let image = try CharacterSheetProcessor.decodePNG(data)
        let grid = ActionSheetProcessor.detectDrawnGrid(image, layout: layout)
        expect(grid != nil, "split strokes must resolve to one separator per panel boundary")

        let result = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: [data], keepCounts: [3])
        expect(result.frames.allSatisfy { $0.bounds.width < 100 && $0.bounds.height < 100 },
               "presentation borders must not survive as foreground bounds")
        expect(result.frames[2].bounds.width == 56,
               "grid cleanup must preserve art that is inside the separator")
    }

    // MARK: - Rejections

    static func testEmptyCellIsRejected() {
        let heights = [70, 70, 70, 70, 0, 70, 70, 70, 70]
        let blobs = heights.enumerated().map { index, height in
            height == 0 ? bounds(0, 0, 0, 0) : bounds(40, 128 - 20 - height, 30, height)
        }
        let sheet = makeSheet(cell: 128, layout: .threeByThree, blobs: blobs)
        do {
            _ = try ActionSheetProcessor.process(pngData: png(sheet), layout: .threeByThree)
            preconditionFailure("an empty cell must fail the whole sheet")
        } catch let error as ActionSheetError {
            guard case .emptyCell(let index) = error else {
                preconditionFailure("expected emptyCell, got \(error)")
            }
            expect(index == 4, "the error names the offending cell, got \(index)")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    /// A subject this short is a misfire, not a crouch.
    static func testTinySubjectIsRejected() {
        var blobs = (0..<9).map { _ in bounds(40, 40, 30, 70) }
        blobs[2] = bounds(40, 100, 20, 8)
        let sheet = makeSheet(cell: 128, layout: .threeByThree, blobs: blobs)
        do {
            _ = try ActionSheetProcessor.process(pngData: png(sheet), layout: .threeByThree)
            preconditionFailure("a tiny subject must be rejected")
        } catch let error as ActionSheetError {
            guard case .cellTooSmall(let index, _, _) = error else {
                preconditionFailure("expected cellTooSmall, got \(error)")
            }
            expect(index == 2, "the error names the offending cell")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testIndivisibleDimensionsAreRejected() {
        var image = CharacterSheetRGBAImage(width: 100, height: 99)
        for index in stride(from: 0, to: image.pixels.count, by: 4) {
            image.pixels[index + 3] = 255
        }
        do {
            _ = try ActionSheetProcessor.process(pngData: png(image))
            preconditionFailure("a sheet that does not divide into the grid must be rejected")
        } catch let error as ActionSheetError {
            guard case .dimensionsNotDivisible = error else {
                preconditionFailure("expected dimensionsNotDivisible, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testNonPNGIsRejected() {
        do {
            _ = try ActionSheetProcessor.process(pngData: Data("not a png".utf8))
            preconditionFailure("non-PNG input must be rejected")
        } catch let error as ActionSheetError {
            guard case .notPNG = error else { preconditionFailure("expected notPNG, got \(error)") }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    // MARK: - Matte handling

    /// The generator paints a flat matte rather than alpha, since neither
    /// backend produces transparent output. It has to come off before slicing,
    /// and cleaning the whole canvas first is why art touching a grid line is
    /// not mistaken for art running off a crop edge.
    static func testFlatMatteIsRemovedBeforeSlicing() throws {
        let heights = [70, 68, 72, 66, 74, 69, 71, 67, 73]
        let blobs = heights.enumerated().map { index, height in
            bounds(40 + (index % 3) * 4, 128 - 20 - height, 30, height)
        }
        let sheet = makeSheet(cell: 128, layout: .threeByThree, blobs: blobs,
                              matte: (241, 236, 226, 255))
        let result = try ActionSheetProcessor.process(pngData: png(sheet), layout: .threeByThree)
        let decoded = try CharacterSheetProcessor.decodePNG(result.pngData)

        // Corners of the first output cell must be transparent, or the matte
        // survived and every sprite ships with a beige box around it.
        for (x, y) in [(2, 2), (result.cellSize - 3, 2)] {
            let offset = (y * decoded.width + x) * 4
            expect(decoded.pixels[offset + 3] == 0,
                   "matte must be gone at (\(x),\(y)), alpha was \(decoded.pixels[offset + 3])")
        }
    }

    /// Real gpt-image batches sometimes put a thin white presentation frame
    /// around the requested magenta field. The outermost row is therefore not
    /// the matte; extraction must find the dominant inset chroma instead.
    static func testChromaMatteSurvivesAWhitePresentationFrame() throws {
        let cell = 128
        let layout = ActionSheetLayout(rows: 1, columns: 3)
        var sheet = makeSheet(
            cell: cell, layout: layout,
            blobs: (0..<3).map { _ in bounds(44, 32, 40, 76) },
            matte: (255, 0, 255, 255))
        for y in 0..<sheet.height {
            for x in 0..<sheet.width
                where x < 4 || x >= sheet.width - 4 || y < 4 || y >= sheet.height - 4 {
                sheet.setRGBA(x: x, y: y, (255, 255, 255, 255))
            }
        }

        let result = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: [png(sheet)], keepCounts: [3])
        let strip = try CharacterSheetProcessor.decodePNG(result.pngData)
        for frame in 0..<3 {
            let cellImage = ActionSheetProcessor.crop(
                strip, x: frame * result.cellSize, y: 0,
                width: result.cellSize, height: result.cellSize)
            expect(cellImage.rgba(x: 2, y: 2).3 == 0,
                   "white-framed chroma must still become transparent in frame \(frame)")
            expect(CharacterSheetProcessor.alphaBounds(of: cellImage)?.width ?? 0 < 200,
                   "the magenta rectangle must not survive as the subject")
        }
    }

    /// Generated antialiasing often blends the character edge with #FF00FF.
    /// Preserve that edge alpha and silhouette, but neutralize chroma in RGB
    /// so compositing on a light card cannot reveal a purple outline.
    static func testMagentaEdgeSpillIsDesaturatedWithoutAlphaContraction() throws {
        let cell = 128
        let layout = ActionSheetLayout(rows: 1, columns: 3)
        var sheet = CharacterSheetRGBAImage(
            width: cell * 3, height: cell, fill: (255, 0, 255, 255))
        for frame in 0..<3 {
            let origin = frame * cell
            for y in 30..<110 {
                for x in 40..<88 {
                    let edge = x < 43 || x >= 85 || y < 33 || y >= 107
                    sheet.setRGBA(
                        x: origin + x, y: y,
                        edge ? (112, 8, 108, 255) : (92, 58, 42, 255))
                }
            }
        }
        let result = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: [png(sheet)], keepCounts: [3])
        let strip = try CharacterSheetProcessor.decodePNG(result.pngData)
        let first = ActionSheetProcessor.crop(
            strip, x: 0, y: 0, width: result.cellSize, height: result.cellSize)
        guard let rendered = CharacterSheetProcessor.alphaBounds(of: first) else {
            preconditionFailure("despill must preserve the subject")
        }
        expect(rendered.width >= 48,
               "despill changes RGB only and must not contract the edge alpha")
        var magentaDominant = 0
        for y in rendered.y..<rendered.maxY {
            for x in rendered.x..<rendered.maxX {
                let pixel = first.rgba(x: x, y: y)
                if pixel.3 > 0 && Int(min(pixel.0, pixel.2)) - Int(pixel.1) > 24 {
                    magentaDominant += 1
                }
            }
        }
        expect(magentaDominant == 0,
               "no visible edge pixel may retain a magenta-key halo")
    }

    /// A magenta-blended dark edge is not opaque black artwork. Chroma
    /// contribution must move into transparency while keeping the edge pixel
    /// present; subtracting magenta from RGB but leaving alpha at 255 creates
    /// the hard black fringe reported on light Settings cards.
    static func testChromaUnmixDoesNotTurnSpillIntoAnOpaqueBlackFringe() {
        var image = CharacterSheetRGBAImage(
            width: 64, height: 64, fill: (255, 0, 255, 255))
        for y in 16..<48 {
            for x in 16..<48 {
                let edge = x < 19 || x >= 45 || y < 19 || y >= 45
                image.setRGBA(
                    x: x, y: y,
                    edge ? (112, 8, 108, 255) : (92, 58, 42, 255))
            }
        }
        CharacterSheetProcessor.removeBorderConnectedMatte(from: &image)
        let edge = image.rgba(x: 17, y: 32)
        expect(edge.3 > 0 && edge.3 < 255,
               "chroma-mixed outline keeps coverage but must become partially transparent")
        let lightComposite = (
            Int(edge.0) + 245 * (255 - Int(edge.3)) / 255
            + Int(edge.1) + 242 * (255 - Int(edge.3)) / 255
            + Int(edge.2) + 236 * (255 - Int(edge.3)) / 255
        ) / 3
        expect(lightComposite > 80,
               "the recovered edge must not composite as an opaque black fringe")
    }

    // MARK: - Layout flexibility

    static func testNonSquareLayoutsWork() throws {
        let layout = ActionSheetLayout(rows: 2, columns: 4)
        let blobs = (0..<8).map { _ in bounds(30, 40, 30, 70) }
        let sheet = makeSheet(cell: 128, layout: layout, blobs: blobs)
        let result = try ActionSheetProcessor.process(pngData: png(sheet), layout: layout)
        expect(result.frames.count == 8, "2x4 yields eight frames")
        let decoded = try CharacterSheetProcessor.decodePNG(result.pngData)
        expect(decoded.width == result.cellSize * 8, "strip width follows the frame count")
    }

    // MARK: - Two-pass walk interleaving

    static func makeStrip(cell: Int, colors: [(UInt8, UInt8, UInt8)], height: Int = 40,
                          horizontalMargin: Int = 12)
        -> CharacterSheetRGBAImage {
        var strip = CharacterSheetRGBAImage(width: cell * colors.count, height: cell)
        for (frame, color) in colors.enumerated() {
            for y in (cell - 8 - height)..<(cell - 8) {
                for x in (frame * cell + horizontalMargin)..<(frame * cell + cell - horizontalMargin) {
                    let offset = (y * strip.width + x) * 4
                    strip.pixels[offset] = color.0
                    strip.pixels[offset + 1] = color.1
                    strip.pixels[offset + 2] = color.2
                    strip.pixels[offset + 3] = 255
                }
            }
        }
        return strip
    }

    static func testInterleavePreservesExactFrameOrder() throws {
        let cell = 64
        let keyframes = makeStrip(cell: cell, colors: [(255, 0, 0), (0, 255, 0)])
        let midpoints = makeStrip(cell: cell, colors: [(0, 0, 255), (255, 255, 0)])
        let data = try ActionSheetProcessor.interleaveStrips(
            keyframesPNG: png(keyframes), inbetweensPNG: png(midpoints))
        let result = try CharacterSheetProcessor.decodePNG(data)
        expect(result.width == cell * 4 && result.height == cell,
               "two 2-frame strips become one 4-frame strip")
        let expected: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 255, 0),
        ]
        for (frame, color) in expected.enumerated() {
            let offset = ((cell - 10) * result.width + frame * cell + cell / 2) * 4
            expect(result.pixels[offset] == color.0
                   && result.pixels[offset + 1] == color.1
                   && result.pixels[offset + 2] == color.2,
                   "frame \(frame) keeps K1,M1,K2,M2 order")
        }
    }

    static func testInterleaveRejectsDifferentFrameCounts() {
        let keyframes = makeStrip(cell: 64, colors: [(255, 0, 0), (0, 255, 0)])
        let midpoint = makeStrip(cell: 64, colors: [(0, 0, 255)])
        do {
            _ = try ActionSheetProcessor.interleaveStrips(
                keyframesPNG: png(keyframes), inbetweensPNG: png(midpoint))
            preconditionFailure("different frame counts must be rejected")
        } catch let error as ActionSheetError {
            guard case .incompatibleStrips = error else {
                preconditionFailure("expected incompatibleStrips, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testInterleaveRejectsScaleDrift() {
        let keyframes = makeStrip(cell: 64, colors: [(255, 0, 0), (0, 255, 0)], height: 40)
        let midpoints = makeStrip(cell: 64, colors: [(0, 0, 255), (255, 255, 0)], height: 25)
        do {
            _ = try ActionSheetProcessor.interleaveStrips(
                keyframesPNG: png(keyframes), inbetweensPNG: png(midpoints))
            preconditionFailure("large generated-character scale drift must be rejected")
        } catch let error as ActionSheetError {
            guard case .stripScaleMismatch(let keyHeight, let midpointHeight) = error else {
                preconditionFailure("expected stripScaleMismatch, got \(error)")
            }
            expect(keyHeight == 40 && midpointHeight == 25,
                   "scale error reports both medians")
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testSparseRepairChangesOnlyRequestedFrames() throws {
        let cell = 64
        let base = makeStrip(cell: cell, colors: [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
        ])
        let repair = makeStrip(cell: cell, colors: [(255, 0, 255), (0, 255, 255)])
        let data = try ActionSheetProcessor.replacingFrames(
            in: png(base), with: png(repair), at: [2, 3])
        let result = try CharacterSheetProcessor.decodePNG(data)
        let expected: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0), (255, 0, 255), (0, 255, 255),
        ]
        for (frame, color) in expected.enumerated() {
            let offset = ((cell - 10) * result.width + frame * cell + cell / 2) * 4
            expect(result.pixels[offset] == color.0
                   && result.pixels[offset + 1] == color.1
                   && result.pixels[offset + 2] == color.2,
                   "sparse repair keeps accepted frames and replaces only targets")
        }
    }

    static func testSparseRepairRejectsDifferentScale() {
        let base = makeStrip(cell: 64, colors: [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
        ], height: 40)
        let repair = makeStrip(cell: 64, colors: [(255, 0, 255), (0, 255, 255)], height: 25)
        do {
            _ = try ActionSheetProcessor.replacingFrames(
                in: png(base), with: png(repair), at: [2, 3])
            preconditionFailure("a visibly smaller local repair must be rejected")
        } catch let error as ActionSheetError {
            guard case .stripScaleMismatch = error else {
                preconditionFailure("expected stripScaleMismatch, got \(error)")
            }
        } catch { preconditionFailure("unexpected \(error)") }
    }

    static func testSparseRepairCanSafelyNormalizeUniformlySmallFrames() throws {
        let base = makeStrip(cell: 64, colors: [
            (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
        ], height: 40)
        let repair = makeStrip(cell: 64, colors: [(255, 0, 255), (0, 255, 255)],
                               height: 32, horizontalMargin: 20)
        let data = try ActionSheetProcessor.replacingFrames(
            in: png(base), with: png(repair), at: [2, 3],
            normalizeSmallerRepairs: true)
        let result = try CharacterSheetProcessor.decodePNG(data)
        for index in 0..<4 {
            let frame = ActionSheetProcessor.crop(
                result, x: index * 64, y: 0, width: 64, height: 64)
            expect(CharacterSheetProcessor.alphaBounds(of: frame)?.height == 40,
                   "uniform local normalization matches the retained median")
        }
    }

    static func testCoherentBatchesShareOneFinalRegistration() throws {
        let layout = ActionSheetLayout(rows: 1, columns: 3)
        let first = makeSheet(
            cell: 128, layout: layout,
            blobs: [
                bounds(44, 32, 38, 76),
                bounds(43, 30, 40, 78),
                bounds(44, 28, 38, 80),
            ],
            matte: (255, 0, 255, 255))
        let second = makeSheet(
            cell: 128, layout: layout,
            blobs: [
                bounds(42, 18, 42, 90),
                bounds(43, 22, 40, 86),
                bounds(42, 20, 42, 88),
            ],
            matte: (255, 0, 255, 255))

        let result = try ActionSheetProcessor.processCoherentBatches(
            pngDatas: [png(first), png(second)], keepCounts: [3, 2])
        expect(result.frames.count == 5 && result.sourceCells.count == 5,
               "closure-check cells are discarded before final assembly")
        expect(Set(result.frames.map(\.anchorY)).count == 1,
               "every retained batch lands on one final baseline")

        let strip = try CharacterSheetProcessor.decodePNG(result.pngData)
        let renderedHeights = (0..<5).map { index -> Int in
            let frame = ActionSheetProcessor.crop(
                strip, x: index * result.cellSize, y: 0,
                width: result.cellSize, height: result.cellSize)
            return CharacterSheetProcessor.alphaBounds(of: frame)!.height
        }
        expect(renderedHeights[3] > renderedHeights[0],
               "one shared scale preserves real cross-batch pose height differences")
        let ratio = Double(renderedHeights[3]) / Double(renderedHeights[0])
        expect(ratio > 1.10 && ratio < 1.25,
               "cross-batch scale remains physically proportional, got \(ratio)")
    }

    static func main() throws {
        try testSlicesEveryCell()
        try testStripGeometryMatchesTheRuntimeContract()
        try testAllFramesShareOneScaleAndBaseline()
        try testFeetLandOnTheBaseline()
        try testNeighbourOverflowIsRemovedFromTheCell()
        testSubjectCutByThePanelEdgeIsRejected()
        try testUnframedHorizontalFamilyRegistersTransparentGutters()
        testFramedBottomContactIsRejected()
        try testSplitStrokePanelBordersAreMerged()
        testSparseLargePanelEdgeContactIsNotClipping()
        testEmptyCellIsRejected()
        testTinySubjectIsRejected()
        testIndivisibleDimensionsAreRejected()
        testNonPNGIsRejected()
        try testFlatMatteIsRemovedBeforeSlicing()
        try testChromaMatteSurvivesAWhitePresentationFrame()
        try testMagentaEdgeSpillIsDesaturatedWithoutAlphaContraction()
        testChromaUnmixDoesNotTurnSpillIntoAnOpaqueBlackFringe()
        try testNonSquareLayoutsWork()
        try testInterleavePreservesExactFrameOrder()
        testInterleaveRejectsDifferentFrameCounts()
        testInterleaveRejectsScaleDrift()
        try testSparseRepairChangesOnlyRequestedFrames()
        testSparseRepairRejectsDifferentScale()
        try testSparseRepairCanSafelyNormalizeUniformlySmallFrames()
        try testCoherentBatchesShareOneFinalRegistration()
        print("action sheet: all assertions passed")
    }
}
