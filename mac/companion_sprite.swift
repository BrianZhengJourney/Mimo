import CoreGraphics
import Foundation
import ImageIO

// Sprite assets for the native companion layer.
//
// A generated familiar ships as one wide PNG holding N equal cells (today
// 1536x512 = three 512px frames; see character_sheet.swift). This slices it,
// finds where the art actually sits inside each cell, and bakes a coarse alpha
// mask for hit testing.
//
// Two things here exist to replace guesses in the current implementation:
//
// The anchor is derived from the art, not assumed. Companion physics puts the
// anchor at the feet, so it is the bottom-centre of the opaque pixels, not the
// bottom-centre of the cell — cells carry uneven padding, and using the cell
// would make a companion hover or sink depending on how the model framed it.
//
// The hit mask is derived from alpha, not from a rectangle. main.swift
// currently tests a hardcoded 260x265 box that has no relationship to the
// artwork, so clicks land on empty space beside the companion and miss thin
// parts of it. See docs/companion/02-mimo-baseline.md.

struct CompanionFrame {
    let image: CGImage
    /// Opaque bounds within the cell, in cell pixels, y-down (CoreGraphics).
    let opaqueBounds: CGRect
    /// Feet, in cell pixels, y-down: bottom-centre of `opaqueBounds`.
    let anchorInCell: CGPoint
    /// Coarse alpha occupancy over `maskResolution` x `maskResolution`.
    let mask: [Bool]
}

struct CompanionSprite {
    static let maskResolution = 48
    /// Alpha at or below this counts as empty. Matte extraction leaves a faint
    /// fringe; treating it as solid would inflate both bounds and hit area.
    static let alphaThreshold: UInt8 = 24

    let frames: [CompanionFrame]
    /// Cell size in source pixels.
    let cellSize: CGSize

    var frameCount: Int { frames.count }

    func frame(_ index: Int) -> CompanionFrame {
        frames[max(0, min(index, frames.count - 1))]
    }

    /// Loads a horizontal strip of `frameCount` equal cells.
    static func load(contentsOf url: URL, frameCount: Int) -> CompanionSprite? {
        guard frameCount > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return slice(sheet: sheet, frameCount: frameCount)
    }

    /// Same, from bytes — the store hands out sheet data rather than paths, so
    /// the companion layer never needs to know where a familiar lives on disk.
    static func load(data: Data, frameCount: Int) -> CompanionSprite? {
        guard frameCount > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return slice(sheet: sheet, frameCount: frameCount)
    }

    static func slice(sheet: CGImage, frameCount: Int) -> CompanionSprite? {
        let cellWidth = sheet.width / frameCount
        let cellHeight = sheet.height
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        var frames: [CompanionFrame] = []
        for index in 0..<frameCount {
            let rect = CGRect(x: index * cellWidth, y: 0, width: cellWidth, height: cellHeight)
            guard let cell = sheet.cropping(to: rect),
                  let alpha = alphaSamples(of: cell) else { return nil }

            let bounds = opaqueBounds(alpha: alpha, width: cell.width, height: cell.height)
            // An empty cell would otherwise produce a degenerate anchor and the
            // companion would render at a nonsense position rather than fail.
            guard !bounds.isEmpty else { return nil }

            frames.append(CompanionFrame(
                image: cell,
                opaqueBounds: bounds,
                anchorInCell: CGPoint(x: bounds.midX, y: bounds.maxY),
                mask: coarseMask(alpha: alpha, width: cell.width, height: cell.height)))
        }
        return CompanionSprite(frames: frames,
                               cellSize: CGSize(width: cellWidth, height: cellHeight))
    }

    // MARK: - Pixel inspection

    /// One alpha byte per pixel, row-major, y-down.
    private static func alphaSamples(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func opaqueBounds(alpha: [UInt8], width: Int, height: Int) -> CGRect {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] > alphaThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    /// Downsamples alpha to a fixed grid. A cell is solid if any pixel in it is.
    ///
    /// Biased toward "solid" on purpose: a click that lands one pixel outside
    /// the art and still grabs the companion is unremarkable, while a click on a
    /// thin ear or tail that falls through to the window below feels broken.
    private static func coarseMask(alpha: [UInt8], width: Int, height: Int) -> [Bool] {
        let resolution = maskResolution
        var mask = [Bool](repeating: false, count: resolution * resolution)
        for y in 0..<height {
            let maskY = min(resolution - 1, y * resolution / height)
            let row = y * width
            let maskRow = maskY * resolution
            for x in 0..<width where alpha[row + x] > alphaThreshold {
                mask[maskRow + min(resolution - 1, x * resolution / width)] = true
            }
        }
        return mask
    }
}

extension CompanionFrame {
    /// Whether `point`, given in the frame's on-screen rect, is on the artwork.
    ///
    /// `rect` is y-up (AppKit); the mask is y-down (image space), so the row is
    /// flipped on lookup.
    func isOpaque(at point: CGPoint, in rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return false }
        let resolution = CompanionSprite.maskResolution
        let u = (point.x - rect.minX) / rect.width
        let v = 1 - (point.y - rect.minY) / rect.height
        let column = min(resolution - 1, max(0, Int(u * CGFloat(resolution))))
        let row = min(resolution - 1, max(0, Int(v * CGFloat(resolution))))
        return mask[row * resolution + column]
    }

    /// Where to place the frame so its anchor lands on `anchor`.
    ///
    /// `displayHeight` scales the whole cell, so every frame keeps one shared
    /// scale and baseline and a frame swap cannot make the companion jump.
    func rect(anchoredAt anchor: CGPoint, displayHeight: CGFloat, cellSize: CGSize) -> CGRect {
        guard cellSize.height > 0 else { return .zero }
        let scale = displayHeight / cellSize.height
        let width = cellSize.width * scale
        let height = cellSize.height * scale
        // anchorInCell is y-down from the cell top; on screen we measure up from
        // the bottom, hence the flip.
        let anchorFromBottom = (cellSize.height - anchorInCell.y) * scale
        return CGRect(x: anchor.x - anchorInCell.x * scale,
                      y: anchor.y - anchorFromBottom,
                      width: width, height: height)
    }
}
