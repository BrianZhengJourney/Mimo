import Foundation

// Slices an action sheet — one image holding an R×C grid of the same character
// in different poses — into the frame strip the runtime plays.
//
// Deliberately separate from CharacterSheetProcessor rather than a
// generalisation of it. That one is tuned for the three-stage evolution sheet
// and carries the boundary-recovery behaviour that path needs; its layout
// assumptions are load-bearing and well covered. An action sheet is a different
// artifact with different geometry and, crucially, a different normalisation
// rule (below). Reusing its matte and alpha primitives while keeping the layout
// separate is cheaper than making one function serve both.
//
// The rule that matters:
//
//   Evolution stages are normalised INDEPENDENTLY — they are meant to differ in
//   size, that is what evolving looks like.
//
//   Action frames must be normalised TOGETHER, sharing one scale and one
//   ground baseline. Fitting each pose to its own cell would make the character
//   change size and hop vertically between frames, and a walk cycle built from
//   that jitters no matter how good the art is.

struct ActionSheetLayout: Equatable {
    let rows: Int
    let columns: Int

    var frameCount: Int { rows * columns }

    /// The production layout: 4×4 in one 2048px square, sixteen frames at
    /// exactly 512px per cell. The cell count must divide the canvas evenly —
    /// the processor rejects anything else — which is what killed the earlier
    /// 3×3-at-2048² plan (2048 % 3 != 0; its "682px cells" never existed).
    static let fourByFour = ActionSheetLayout(rows: 4, columns: 4)

    /// Kept for tests exercising non-square layouts; not generable at 2048².
    static let threeByThree = ActionSheetLayout(rows: 3, columns: 3)
}

enum ActionSheetError: Error, CustomStringConvertible {
    case notPNG
    case unreadableImage
    case dimensionsNotDivisible(width: Int, height: Int, layout: ActionSheetLayout)
    case emptyCell(index: Int)
    case cellTooSmall(index: Int, height: Int, minimum: Int)
    case subjectClipped(index: Int, edge: String)
    case noUsableFrames
    case incompatibleStrips(reason: String)
    case stripScaleMismatch(keyframeMedian: Int, inbetweenMedian: Int)

    var description: String {
        switch self {
        case .notPNG: return "action sheet is not a PNG"
        case .unreadableImage: return "action sheet could not be decoded"
        case .dimensionsNotDivisible(let width, let height, let layout):
            return "\(width)x\(height) does not divide into \(layout.columns)x\(layout.rows) cells"
        case .emptyCell(let index): return "cell \(index) has no artwork"
        case .cellTooSmall(let index, let height, let minimum):
            return "cell \(index) is only \(height)px tall, under the \(minimum)px minimum"
        case .subjectClipped(let index, let edge):
            return "cell \(index)'s subject is cut off at its \(edge) edge — the art "
                 + "overflowed the panel and the missing part cannot be recovered"
        case .noUsableFrames: return "no usable frames in the action sheet"
        case .incompatibleStrips(let reason): return "action strips are incompatible: \(reason)"
        case .stripScaleMismatch(let keyframeMedian, let inbetweenMedian):
            return "inbetween character scale differs from keyframes "
                 + "(median heights \(inbetweenMedian)px vs \(keyframeMedian)px)"
        }
    }
}

struct ActionSheetFrameMetrics: Equatable {
    let index: Int
    /// Opaque bounds within the source cell.
    let bounds: CharacterSheetPixelBounds
    /// Where the feet ended up in the output frame, in output pixels.
    let anchorX: Int
    let anchorY: Int
}

struct ActionSheetResult {
    /// Horizontal strip of `frameCount` cells, each `cellSize` square.
    let pngData: Data
    let layout: ActionSheetLayout
    let cellSize: Int
    let frames: [ActionSheetFrameMetrics]
    /// Cells sliced out of the source, for the consistency gate to score.
    let sourceCells: [CharacterSheetRGBAImage]
}

enum ActionSheetProcessor {
    /// Output cell edge. Matches the existing runtime contract so a behaviour
    /// pack does not need to know which artifact its frames came from.
    static let outputCellSize = 512
    /// Padding inside the output cell, matching the evolution path so both
    /// clear the transparent border CustomPetStore validates.
    static let outputPadding = 10
    /// A frame whose subject is shorter than this is almost certainly a
    /// misfire rather than a crouch.
    static let minimumSubjectHeight = 48
    /// Extra crop inside a detected frame band, clearing the line's
    /// antialiased fringe.
    static let frameFringeInset = 8
    /// A row or column this dark-saturated is a frame line. The requested
    /// frame color is near-black; the matte and the character are not.
    static let frameBandCoverage = 0.6

    /// Interleaves accepted keyframes and generated temporal midpoints without
    /// resampling either strip: K1,M1,K2,M2… This keeps the first-pass art
    /// pixel-for-pixel and avoids the ghosting introduced by local blending.
    static func interleaveStrips(keyframesPNG: Data, inbetweensPNG: Data,
                                 maximumMedianScaleDrift: Double = 0.08) throws -> Data {
        let keyframes = try CharacterSheetProcessor.decodePNG(keyframesPNG)
        let inbetweens = try CharacterSheetProcessor.decodePNG(inbetweensPNG)
        guard keyframes.height > 0, inbetweens.height > 0,
              keyframes.height == inbetweens.height else {
            throw ActionSheetError.incompatibleStrips(reason: "cell heights differ")
        }
        guard keyframes.width % keyframes.height == 0,
              inbetweens.width % inbetweens.height == 0 else {
            throw ActionSheetError.incompatibleStrips(reason: "each input must be a one-cell-tall strip")
        }
        let keyframeCount = keyframes.width / keyframes.height
        let inbetweenCount = inbetweens.width / inbetweens.height
        guard keyframeCount > 0, keyframeCount == inbetweenCount else {
            throw ActionSheetError.incompatibleStrips(
                reason: "frame counts differ (\(keyframeCount) vs \(inbetweenCount))")
        }

        func subjectHeights(_ strip: CharacterSheetRGBAImage, count: Int) throws -> [Int] {
            try (0..<count).map { index in
                let cell = crop(strip, x: index * strip.height, y: 0,
                                width: strip.height, height: strip.height)
                guard let bounds = CharacterSheetProcessor.alphaBounds(of: cell) else {
                    throw ActionSheetError.emptyCell(index: index)
                }
                return bounds.height
            }
        }
        let keyHeights = try subjectHeights(keyframes, count: keyframeCount).sorted()
        let midpointHeights = try subjectHeights(inbetweens, count: inbetweenCount).sorted()
        let keyMedian = keyHeights[keyHeights.count / 2]
        let midpointMedian = midpointHeights[midpointHeights.count / 2]
        let scaleDrift = abs(Double(midpointMedian - keyMedian)) / Double(max(1, keyMedian))
        guard scaleDrift <= maximumMedianScaleDrift else {
            throw ActionSheetError.stripScaleMismatch(
                keyframeMedian: keyMedian, inbetweenMedian: midpointMedian)
        }

        let cell = keyframes.height
        var output = CharacterSheetRGBAImage(width: cell * keyframeCount * 2, height: cell)
        func copy(_ source: CharacterSheetRGBAImage, sourceFrame: Int, destinationFrame: Int) {
            let sourceX = sourceFrame * cell
            let destinationX = destinationFrame * cell
            for y in 0..<cell {
                let sourceStart = (y * source.width + sourceX) * 4
                let destinationStart = (y * output.width + destinationX) * 4
                output.pixels.replaceSubrange(
                    destinationStart..<(destinationStart + cell * 4),
                    with: source.pixels[sourceStart..<(sourceStart + cell * 4)])
            }
        }
        for index in 0..<keyframeCount {
            copy(keyframes, sourceFrame: index, destinationFrame: index * 2)
            copy(inbetweens, sourceFrame: index, destinationFrame: index * 2 + 1)
        }
        return try CharacterSheetProcessor.encodePNG(output)
    }

    /// Replaces a sparse set of frames in an existing one-cell-tall strip.
    /// Used by paid surgical repairs: accepted frames remain pixel-identical,
    /// and only the rejected indices are copied from the small retry sheet.
    static func replacingFrames(in stripPNG: Data, with replacementsPNG: Data,
                                at indices: [Int],
                                maximumMedianScaleDrift: Double = 0.08,
                                normalizeSmallerRepairs: Bool = false) throws -> Data {
        var strip = try CharacterSheetProcessor.decodePNG(stripPNG)
        var replacements = try CharacterSheetProcessor.decodePNG(replacementsPNG)
        guard strip.height > 0, replacements.height == strip.height,
              strip.width % strip.height == 0,
              replacements.width % replacements.height == 0 else {
            throw ActionSheetError.incompatibleStrips(
                reason: "repair inputs must use the same square cell size")
        }
        let frameCount = strip.width / strip.height
        let replacementCount = replacements.width / replacements.height
        guard indices.count == replacementCount, Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<frameCount).contains($0) }) else {
            throw ActionSheetError.incompatibleStrips(
                reason: "repair indices do not match the replacement frames")
        }

        func heights(_ image: CharacterSheetRGBAImage, frames: [Int]) throws -> [Int] {
            try frames.map { index in
                let cell = crop(image, x: index * image.height, y: 0,
                                width: image.height, height: image.height)
                guard let bounds = CharacterSheetProcessor.alphaBounds(of: cell) else {
                    throw ActionSheetError.emptyCell(index: index)
                }
                return bounds.height
            }
        }
        let retainedIndices = (0..<frameCount).filter { !indices.contains($0) }
        if !retainedIndices.isEmpty {
            let retained = try heights(strip, frames: retainedIndices).sorted()
            var repaired = try heights(replacements, frames: Array(0..<replacementCount)).sorted()
            let retainedMedian = retained[retained.count / 2]
            var repairedMedian = repaired[repaired.count / 2]
            var drift = abs(Double(repairedMedian - retainedMedian))
                / Double(max(1, retainedMedian))
            if drift > maximumMedianScaleDrift,
               normalizeSmallerRepairs, repairedMedian < retainedMedian {
                let normalized = try normalizingStripScale(
                    replacementsPNG, toMedianHeight: retainedMedian)
                replacements = try CharacterSheetProcessor.decodePNG(normalized)
                repaired = try heights(replacements,
                                       frames: Array(0..<replacementCount)).sorted()
                repairedMedian = repaired[repaired.count / 2]
                drift = abs(Double(repairedMedian - retainedMedian))
                    / Double(max(1, retainedMedian))
            }
            guard drift <= maximumMedianScaleDrift else {
                throw ActionSheetError.stripScaleMismatch(
                    keyframeMedian: retainedMedian, inbetweenMedian: repairedMedian)
            }
        }

        let cell = strip.height
        for (replacementIndex, destinationIndex) in indices.enumerated() {
            for y in 0..<cell {
                let sourceStart = (y * replacements.width + replacementIndex * cell) * 4
                let destinationStart = (y * strip.width + destinationIndex * cell) * 4
                strip.pixels.replaceSubrange(
                    destinationStart..<(destinationStart + cell * 4),
                    with: replacements.pixels[sourceStart..<(sourceStart + cell * 4)])
            }
        }
        return try CharacterSheetProcessor.encodePNG(strip)
    }

    /// Applies one uniform nearest-neighbour scale to every frame and restores
    /// the shared feet baseline. This is intentionally opt-in: it is safe for
    /// a complete, internally consistent local repair that came back uniformly
    /// too small, but must not hide arbitrary per-frame generation drift.
    static func normalizingStripScale(_ pngData: Data, toMedianHeight target: Int,
                                      maximumUpscale: Double = 1.3) throws -> Data {
        let source = try CharacterSheetProcessor.decodePNG(pngData)
        guard source.height > 0, source.width % source.height == 0, target > 0 else {
            throw ActionSheetError.incompatibleStrips(reason: "cannot normalize this strip")
        }
        let cell = source.height
        let count = source.width / cell
        var frames: [(image: CharacterSheetRGBAImage, bounds: CharacterSheetPixelBounds)] = []
        for index in 0..<count {
            let image = crop(source, x: index * cell, y: 0, width: cell, height: cell)
            guard let bounds = CharacterSheetProcessor.alphaBounds(of: image) else {
                throw ActionSheetError.emptyCell(index: index)
            }
            frames.append((image, bounds))
        }
        let heights = frames.map(\.bounds.height).sorted()
        let median = heights[heights.count / 2]
        let scale = Double(target) / Double(max(1, median))
        guard scale >= 1.0, scale <= maximumUpscale else {
            throw ActionSheetError.incompatibleStrips(
                reason: String(format: "repair scale %.3f is outside the safe upscale range", scale))
        }
        let baseline = cell - outputPadding
        var output = CharacterSheetRGBAImage(width: source.width, height: cell)
        for (index, frame) in frames.enumerated() {
            let width = max(1, Int((Double(frame.bounds.width) * scale).rounded()))
            let height = max(1, Int((Double(frame.bounds.height) * scale).rounded()))
            guard width <= cell - outputPadding * 2,
                  height <= cell - outputPadding * 2 else {
                throw ActionSheetError.incompatibleStrips(
                    reason: "normalized repair frame \(index) would not fit")
            }
            let x = index * cell + (cell - width) / 2
            let y = baseline - height
            drawScaled(frame.image, from: frame.bounds, into: &output,
                       destinationX: x, destinationY: y, width: width, height: height)
        }
        return try CharacterSheetProcessor.encodePNG(output)
    }

    static func process(pngData: Data,
                        layout: ActionSheetLayout = .fourByFour,
                        outputCellSize: Int = ActionSheetProcessor.outputCellSize) throws
        -> ActionSheetResult {
        guard pngData.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw ActionSheetError.notPNG
        }
        var source = try CharacterSheetProcessor.decodePNG(pngData)
        guard source.width > 0, source.height > 0 else { throw ActionSheetError.unreadableImage }
        guard source.width % layout.columns == 0, source.height % layout.rows == 0 else {
            throw ActionSheetError.dimensionsNotDivisible(
                width: source.width, height: source.height, layout: layout)
        }

        // Grid detection must PRECEDE any cleaning: the canvas border ring is
        // the frame itself, so the whole-canvas matte pass would sample the
        // dark ring as "the matte" and flood the entire grid away before it
        // could be read.
        let drawnGrid = detectDrawnGrid(source, layout: layout)
        if drawnGrid == nil {
            // No frame: the pre-frame contract. Clean the whole canvas before
            // partitioning so the artificial grid lines do not behave like
            // physical crop edges. Framed sheets are cleaned per panel below,
            // since their frame encloses each panel's matte.
            CharacterSheetProcessor.removeBorderConnectedMatte(from: &source)
            CharacterSheetProcessor.removeSmallSpecks(from: &source)
        }

        // The model draws its own grid: asked for frames on a 512 grid it
        // delivers frames on ITS grid — rows 573, 523, 490, and 462 tall on
        // the first real framed sheet. So the drawn lines are treated as
        // registration, not decoration: panels are sliced along the detected
        // bands, and each panel carries a height-normalising scale so the
        // model's uneven rows cannot make the character change size between
        // frames. Sheets with no detectable grid (older art, synthetic
        // fixtures) fall back to the uniform grid.
        let rowRanges = drawnGrid?.rows ?? uniformRanges(total: source.height, count: layout.rows)
        let columnRanges = drawnGrid?.columns ?? uniformRanges(total: source.width, count: layout.columns)
        let referencePanelHeight = Double(rowRanges.map(\.count).sorted()[rowRanges.count / 2])

        var cells: [CharacterSheetRGBAImage] = []
        var bounds: [CharacterSheetPixelBounds] = []
        var panelScales: [Double] = []
        for rowRange in rowRanges {
            for columnRange in columnRanges {
                let index = cells.count
                var cell = crop(source,
                                x: columnRange.lowerBound, y: rowRange.lowerBound,
                                width: columnRange.count, height: rowRange.count)
                // A drawn frame encloses each panel's matte, so framed sheets
                // are cleaned per panel: the sliced cell's background touches
                // its own borders and floods away cleanly. Only on framed
                // sheets — on a transparent fixture, a subject touching the
                // border would itself be sampled as "the matte" and erased.
                if drawnGrid != nil {
                    CharacterSheetProcessor.removeBorderConnectedMatte(from: &cell)
                    CharacterSheetProcessor.removeSmallSpecks(from: &cell)
                }
                // A neighbour's overflow (feet through the top grid line, a
                // hand through the side) would otherwise inflate this cell's
                // bounds — shrinking the subject and floating stray shoes
                // above her head on screen.
                CharacterSheetProcessor.removeEdgeIntruders(from: &cell)
                // The mirror failure is the subject's own overflow: feet drawn
                // on the grid line are feet amputated by it, and no amount of
                // slicing can restore the missing toes. The current prompt
                // reserves a concrete 96px bottom safety zone, so contact with
                // a bottom frame is a defect too. The old exception for a
                // model using the frame bar as its floor let an entire cropped
                // last row pass as four half-bodied sprites.
                if let edge = clippedEdge(of: cell) {
                    throw ActionSheetError.subjectClipped(index: index, edge: edge)
                }
                guard let cellBounds = CharacterSheetProcessor.alphaBounds(of: cell) else {
                    throw ActionSheetError.emptyCell(index: index)
                }
                guard cellBounds.height >= minimumSubjectHeight else {
                    throw ActionSheetError.cellTooSmall(index: index, height: cellBounds.height,
                                                        minimum: minimumSubjectHeight)
                }
                cells.append(cell)
                bounds.append(cellBounds)
                panelScales.append(referencePanelHeight / Double(rowRange.count))
            }
        }
        guard !cells.isEmpty else { throw ActionSheetError.noUsableFrames }

        // One scale for every frame, taken from the tallest height-normalised
        // subject so nothing is clipped. Per-frame fitting is what makes a
        // walk cycle bob; the per-panel factor only undoes panel-size
        // variation, never pose variation.
        let usableHeight = outputCellSize - outputPadding * 2
        let tallest = zip(bounds, panelScales)
            .map { Double($0.height) * $1 }.max() ?? Double(usableHeight)
        let scale = min(1.0, Double(usableHeight) / tallest)

        var strip = CharacterSheetRGBAImage(width: outputCellSize * cells.count,
                                            height: outputCellSize)
        var metrics: [ActionSheetFrameMetrics] = []
        // One baseline for every frame: feet land on the same output row
        // regardless of how the pose sat inside its source cell.
        let baseline = outputCellSize - outputPadding

        for (index, cell) in cells.enumerated() {
            let cellBounds = bounds[index]
            let drawScale = scale * panelScales[index]
            let scaledWidth = max(1, Int((Double(cellBounds.width) * drawScale).rounded()))
            let scaledHeight = max(1, Int((Double(cellBounds.height) * drawScale).rounded()))
            let destinationX = index * outputCellSize + (outputCellSize - scaledWidth) / 2
            let destinationY = baseline - scaledHeight

            drawScaled(cell, from: cellBounds, into: &strip,
                       destinationX: destinationX, destinationY: destinationY,
                       width: scaledWidth, height: scaledHeight)

            metrics.append(ActionSheetFrameMetrics(
                index: index,
                bounds: cellBounds,
                anchorX: (outputCellSize - scaledWidth) / 2 + scaledWidth / 2,
                anchorY: baseline))
        }

        return ActionSheetResult(pngData: try CharacterSheetProcessor.encodePNG(strip),
                                 layout: layout,
                                 cellSize: outputCellSize,
                                 frames: metrics,
                                 sourceCells: cells)
    }

    // MARK: - Drawn-grid registration

    /// Panel pixel ranges under a uniform grid — the pre-frame contract, kept
    /// for older sheets and synthetic fixtures.
    static func uniformRanges(total: Int, count: Int) -> [Range<Int>] {
        let size = total / count
        return (0..<count).map { ($0 * size)..<(($0 + 1) * size) }
    }

    /// Finds the near-black frame lines the model was asked to draw and
    /// returns the panel content ranges between them, or nil when the sheet
    /// has no readable grid. A line is a run of rows (or columns) whose dark
    /// coverage exceeds `frameBandCoverage`; the grid is accepted only when
    /// exactly the expected number of interior lines exists on each axis —
    /// anything else means the model ignored the frame instruction, and the
    /// uniform fallback with its clipping checks takes over.
    static func detectDrawnGrid(_ image: CharacterSheetRGBAImage,
                                layout: ActionSheetLayout)
        -> (rows: [Range<Int>], columns: [Range<Int>])? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var darkPerRow = [Int](repeating: 0, count: height)
        var darkPerColumn = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                let brightness = Int(image.pixels[pixel]) + Int(image.pixels[pixel + 1])
                    + Int(image.pixels[pixel + 2])
                if image.pixels[pixel + 3] > 0, brightness < 300 {
                    darkPerRow[y] += 1
                    darkPerColumn[x] += 1
                }
            }
        }

        func contentRanges(counts: [Int], threshold: Int, expectedPanels: Int,
                           fringeLow: Int, fringeHigh: Int) -> [Range<Int>]? {
            var runs: [(start: Int, end: Int)] = []
            var start: Int?
            for (index, count) in counts.enumerated() {
                if count >= threshold {
                    if start == nil { start = index }
                } else if let s = start {
                    runs.append((s, index - 1)); start = nil
                }
            }
            if let s = start { runs.append((s, counts.count - 1)) }

            let interior = runs.filter { $0.start > 0 && $0.end < counts.count - 1 }
            guard interior.count == expectedPanels - 1 else { return nil }
            let leading = runs.first { $0.start == 0 }
            let trailing = runs.first { $0.end == counts.count - 1 }

            var edges: [Int] = [(leading.map { $0.end + 1 } ?? 0)]
            for run in interior {
                edges.append(run.start)
                edges.append(run.end + 1)
            }
            edges.append(trailing.map(\.start) ?? counts.count)

            var ranges: [Range<Int>] = []
            for panel in 0..<expectedPanels {
                let low = edges[panel * 2] + fringeLow
                let high = edges[panel * 2 + 1] - fringeHigh
                // A panel narrower than the output cell's usable core is a
                // misread, not a grid.
                guard high - low >= minimumSubjectHeight * 2 else { return nil }
                ranges.append(low..<high)
            }
            return ranges
        }

        // The model treats each panel's bottom frame bar as the floor and
        // stands the character ON it, so the sole ends exactly where the bar
        // begins — a bottom fringe would shave the shoes. Rows keep the full
        // fringe on top only, with two pixels at the bottom for the bar's
        // antialiased edge.
        guard let rows = contentRanges(counts: darkPerRow,
                                       threshold: Int(Double(width) * frameBandCoverage),
                                       expectedPanels: layout.rows,
                                       fringeLow: frameFringeInset, fringeHigh: 2),
              let columns = contentRanges(counts: darkPerColumn,
                                          threshold: Int(Double(height) * frameBandCoverage),
                                          expectedPanels: layout.columns,
                                          fringeLow: frameFringeInset,
                                          fringeHigh: frameFringeInset) else { return nil }
        return (rows, columns)
    }

    // MARK: - Pixel work

    /// Alpha at or below the sprite loader's threshold counts as empty here
    /// too, so a faint matte fringe cannot read as a clipped subject.
    static let clipAlphaThreshold: UInt8 = 24
    /// Contact this wide against a cell edge means the subject was cut by the
    /// grid, not merely near it.
    static let clipContactMinimum = 12

    /// The edge the subject is cut off at, or nil if it sits clear of all four.
    static func clippedEdge(of cell: CharacterSheetRGBAImage) -> String? {
        let width = cell.width, height = cell.height
        guard width > 0, height > 0 else { return nil }
        func opaque(x: Int, y: Int) -> Bool {
            cell.pixels[(y * width + x) * 4 + 3] > clipAlphaThreshold
        }
        var bottom = 0, top = 0, left = 0, right = 0
        for x in 0..<width {
            if opaque(x: x, y: height - 1) { bottom += 1 }
            if opaque(x: x, y: 0) { top += 1 }
        }
        for y in 0..<height {
            if opaque(x: 0, y: y) { left += 1 }
            if opaque(x: width - 1, y: y) { right += 1 }
        }
        if bottom >= clipContactMinimum { return "bottom" }
        if top >= clipContactMinimum { return "top" }
        if left >= clipContactMinimum { return "left" }
        if right >= clipContactMinimum { return "right" }
        return nil
    }

    static func crop(_ source: CharacterSheetRGBAImage,
                     x: Int, y: Int, width: Int, height: Int) -> CharacterSheetRGBAImage {
        var result = CharacterSheetRGBAImage(width: width, height: height)
        for row in 0..<height {
            let sourceRow = y + row
            guard sourceRow >= 0, sourceRow < source.height else { continue }
            let sourceStart = (sourceRow * source.width + x) * 4
            let destinationStart = row * width * 4
            let count = min(width * 4, source.pixels.count - sourceStart)
            guard count > 0 else { continue }
            result.pixels.replaceSubrange(destinationStart..<(destinationStart + count),
                                          with: source.pixels[sourceStart..<(sourceStart + count)])
        }
        return result
    }

    /// Nearest-neighbour box scale of `region` into the destination.
    ///
    /// Nearest-neighbour on purpose: these frames are pixel-styled sprite art,
    /// and bilinear smoothing turns crisp stepped edges into mush. The raster
    /// portrait path wants the opposite and has its own downscale.
    private static func drawScaled(_ source: CharacterSheetRGBAImage,
                                   from region: CharacterSheetPixelBounds,
                                   into destination: inout CharacterSheetRGBAImage,
                                   destinationX: Int, destinationY: Int,
                                   width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        for y in 0..<height {
            let sourceY = region.y + min(region.height - 1, y * region.height / height)
            let destinationRow = destinationY + y
            guard destinationRow >= 0, destinationRow < destination.height else { continue }
            for x in 0..<width {
                let sourceX = region.x + min(region.width - 1, x * region.width / width)
                let destinationColumn = destinationX + x
                guard destinationColumn >= 0, destinationColumn < destination.width else { continue }
                let from = (sourceY * source.width + sourceX) * 4
                let to = (destinationRow * destination.width + destinationColumn) * 4
                guard from + 3 < source.pixels.count, to + 3 < destination.pixels.count else { continue }
                destination.pixels[to] = source.pixels[from]
                destination.pixels[to + 1] = source.pixels[from + 1]
                destination.pixels[to + 2] = source.pixels[from + 2]
                destination.pixels[to + 3] = source.pixels[from + 3]
            }
        }
    }
}
