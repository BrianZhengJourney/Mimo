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

    /// 3×3 in one 2048px square: nine poses at ~682px per cell, versus ~512 for
    /// a 1536px sheet. Per-cell resolution is the binding constraint on
    /// contact-sheet quality, and 2048² is legal on gpt-image-2.
    static let threeByThree = ActionSheetLayout(rows: 3, columns: 3)
}

enum ActionSheetError: Error, CustomStringConvertible {
    case notPNG
    case unreadableImage
    case dimensionsNotDivisible(width: Int, height: Int, layout: ActionSheetLayout)
    case emptyCell(index: Int)
    case cellTooSmall(index: Int, height: Int, minimum: Int)
    case noUsableFrames

    var description: String {
        switch self {
        case .notPNG: return "action sheet is not a PNG"
        case .unreadableImage: return "action sheet could not be decoded"
        case .dimensionsNotDivisible(let width, let height, let layout):
            return "\(width)x\(height) does not divide into \(layout.columns)x\(layout.rows) cells"
        case .emptyCell(let index): return "cell \(index) has no artwork"
        case .cellTooSmall(let index, let height, let minimum):
            return "cell \(index) is only \(height)px tall, under the \(minimum)px minimum"
        case .noUsableFrames: return "no usable frames in the action sheet"
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

    static func process(pngData: Data,
                        layout: ActionSheetLayout = .threeByThree,
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

        // Clean the whole canvas before partitioning, for the same reason the
        // evolution path does: cleaning each cell separately makes the
        // artificial grid lines behave like physical crop edges and rejects
        // art that merely touches one.
        CharacterSheetProcessor.removeBorderConnectedMatte(from: &source)
        CharacterSheetProcessor.removeSmallSpecks(from: &source)

        let cellWidth = source.width / layout.columns
        let cellHeight = source.height / layout.rows

        var cells: [CharacterSheetRGBAImage] = []
        var bounds: [CharacterSheetPixelBounds] = []
        for row in 0..<layout.rows {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                let cell = crop(source,
                                x: column * cellWidth, y: row * cellHeight,
                                width: cellWidth, height: cellHeight)
                guard let cellBounds = CharacterSheetProcessor.alphaBounds(of: cell) else {
                    throw ActionSheetError.emptyCell(index: index)
                }
                guard cellBounds.height >= minimumSubjectHeight else {
                    throw ActionSheetError.cellTooSmall(index: index, height: cellBounds.height,
                                                        minimum: minimumSubjectHeight)
                }
                cells.append(cell)
                bounds.append(cellBounds)
            }
        }
        guard !cells.isEmpty else { throw ActionSheetError.noUsableFrames }

        // One scale for every frame, taken from the tallest subject so nothing
        // is clipped. Per-frame fitting is what makes a walk cycle bob.
        let usableHeight = outputCellSize - outputPadding * 2
        let tallest = bounds.map(\.height).max() ?? usableHeight
        let scale = min(1.0, Double(usableHeight) / Double(tallest))

        var strip = CharacterSheetRGBAImage(width: outputCellSize * cells.count,
                                            height: outputCellSize)
        var metrics: [ActionSheetFrameMetrics] = []
        // One baseline for every frame: feet land on the same output row
        // regardless of how the pose sat inside its source cell.
        let baseline = outputCellSize - outputPadding

        for (index, cell) in cells.enumerated() {
            let cellBounds = bounds[index]
            let scaledWidth = max(1, Int((Double(cellBounds.width) * scale).rounded()))
            let scaledHeight = max(1, Int((Double(cellBounds.height) * scale).rounded()))
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

    // MARK: - Pixel work

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
