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
// By default the anchor is derived from the art, not assumed. Action pipelines
// may instead author one fixed registration point shared by every frame; that
// prevents an AI-generated silhouette change from moving the physical feet.
//
// The hit mask is derived from alpha, not from a rectangle. main.swift
// currently tests a hardcoded 260x265 box that has no relationship to the
// artwork, so clicks land on empty space beside the companion and miss thin
// parts of it. See docs/companion/02-mimo-baseline.md.

struct CompanionFrame {
    let image: CGImage
    /// Opaque bounds within the cell, in cell pixels, y-down (CoreGraphics).
    let opaqueBounds: CGRect
    /// Registration point in cell pixels, y-down. Usually the derived feet;
    /// for authored action strips it can be one fixed point across all frames.
    let anchorInCell: CGPoint
    /// Coarse alpha occupancy over `maskResolution` x `maskResolution`.
    let mask: [Bool]
}

/// What a frame index means in a given sheet.
///
/// Three sheets carry three unrelated meanings behind one integer, and letting
/// them mix produced a real bug: a familiar appeared in its mature form and
/// reverted to the seed form the moment it landed, because the behaviour pack's
/// pose index 0 was written for an action sheet but was being applied to a
/// stage sheet, where 0 is the youngest form.
enum CompanionFrameSemantics {
    /// Evolution stages. The art layer picks; behaviour must not.
    case stages
    /// NEUTRAL / JOY / REST for one stage. The art layer picks.
    case expressions
    /// Poses of one animation. Behaviour picks.
    case actionPoses
}

/// Timing facts authored with an action asset. The source bundle speaks in
/// cell pixels; physics speaks in screen pixels, so conversion belongs at the
/// render boundary where both dimensions are known.
struct CompanionActionPlaybackSpec: Equatable {
    let framesPerSecond: CGFloat
    let cycleDistanceInCellPixels: CGFloat?
    /// Optional authored preview timing. Behavior-pack actions keep using
    /// their per-pose `hold`; this preserves that same rhythm when a bundled
    /// strip is reviewed outside the behavior pack.
    let frameDurationsSeconds: [CGFloat]?
    /// Optional one-shot prefix for previews. After this frame boundary, only
    /// the suffix loops. Production sleep uses settle 0...2 once, then breath
    /// 3...5 until an interaction interrupts it.
    let loopStartFrame: Int?

    init(framesPerSecond: CGFloat, cycleDistanceInCellPixels: CGFloat?,
         frameDurationsSeconds: [CGFloat]? = nil,
         loopStartFrame: Int? = nil) {
        self.framesPerSecond = framesPerSecond
        self.cycleDistanceInCellPixels = cycleDistanceInCellPixels
        self.frameDurationsSeconds = frameDurationsSeconds
        self.loopStartFrame = loopStartFrame
    }

    func cycleDistanceOnScreen(displayHeight: CGFloat,
                               cellHeight: CGFloat) -> CGFloat? {
        guard let source = cycleDistanceInCellPixels,
              source.isFinite, source > 0,
              displayHeight.isFinite, displayHeight > 0,
              cellHeight.isFinite, cellHeight > 0 else { return nil }
        return source * displayHeight / cellHeight
    }

    func frameIndex(at elapsed: CGFloat, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        if let durations = frameDurationsSeconds,
           durations.count == frameCount,
           durations.allSatisfy({ $0.isFinite && $0 > 0 }) {
            let loopStart = loopStartFrame.flatMap {
                (1..<frameCount).contains($0) ? $0 : nil
            }
            let firstIndex: Int
            var cursor: CGFloat
            if let loopStart {
                let introDuration = durations[..<loopStart].reduce(0, +)
                if max(0, elapsed) < introDuration {
                    firstIndex = 0
                    cursor = max(0, elapsed)
                } else {
                    firstIndex = loopStart
                    let loopDuration = durations[loopStart...].reduce(0, +)
                    cursor = (max(0, elapsed) - introDuration)
                        .truncatingRemainder(dividingBy: loopDuration)
                }
            } else {
                firstIndex = 0
                let total = durations.reduce(0, +)
                cursor = max(0, elapsed).truncatingRemainder(dividingBy: total)
            }
            for index in firstIndex..<frameCount {
                let duration = durations[index]
                if cursor < duration { return index }
                cursor -= duration
            }
            return frameCount - 1
        }
        let fps = framesPerSecond.isFinite && framesPerSecond > 0
            ? framesPerSecond : 12
        if let loopStart = loopStartFrame,
           (1..<frameCount).contains(loopStart) {
            let introDuration = CGFloat(loopStart) / fps
            if max(0, elapsed) < introDuration {
                return min(loopStart - 1, Int(max(0, elapsed) * fps))
            }
            return loopStart + Int((max(0, elapsed) - introDuration) * fps)
                % (frameCount - loopStart)
        }
        return Int(max(0, elapsed) * fps) % frameCount
    }
}

/// One cell in a top-to-bottom atlas such as OpenAI HatchPet's 8×11 v2 sheet.
struct CompanionAtlasCell: Equatable {
    let row: Int
    let column: Int
}

struct CompanionSprite {
    static let maskResolution = 48
    /// Alpha at or below this counts as empty. Matte extraction leaves a faint
    /// fringe; treating it as solid would inflate both bounds and hit area.
    static let alphaThreshold: UInt8 = 24

    let frames: [CompanionFrame]
    /// Cell size in source pixels.
    let cellSize: CGSize
    /// What `frameIndex` selects. Only `.actionPoses` may be driven by a
    /// behaviour pack.
    var semantics: CompanionFrameSemantics = .stages

    /// Whether a behaviour pack's authored pose index applies to this sheet.
    var framesAreBehaviourDriven: Bool { semantics == .actionPoses }

    var frameCount: Int { frames.count }

    func frame(_ index: Int) -> CompanionFrame {
        frames[max(0, min(index, frames.count - 1))]
    }

    /// Loads a horizontal strip of `frameCount` equal cells.
    static func load(contentsOf url: URL, frameCount: Int,
                     semantics: CompanionFrameSemantics = .stages,
                     fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        guard frameCount > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return slice(sheet: sheet, frameCount: frameCount, semantics: semantics,
                     fixedAnchorInCell: fixedAnchorInCell)
    }

    /// Same, from bytes — the store hands out sheet data rather than paths, so
    /// the companion layer never needs to know where a familiar lives on disk.
    static func load(data: Data, frameCount: Int,
                     semantics: CompanionFrameSemantics = .stages,
                     fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        guard frameCount > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return slice(sheet: sheet, frameCount: frameCount, semantics: semantics,
                     fixedAnchorInCell: fixedAnchorInCell)
    }

    /// Infers the frame count from the strip itself: every sheet this app
    /// produces — stages, expressions, action strips — is a horizontal run of
    /// square cells, so the count is simply width over height. This is what
    /// lets an 8-frame walk strip and a 3-frame stage sheet share one loader
    /// without anyone maintaining a count table.
    static func load(data: Data,
                     semantics: CompanionFrameSemantics,
                     fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
              sheet.height > 0, sheet.width % sheet.height == 0 else { return nil }
        return slice(sheet: sheet, frameCount: sheet.width / sheet.height,
                     semantics: semantics, fixedAnchorInCell: fixedAnchorInCell)
    }

    /// Loads an ordered set of cells from a rectangular atlas without first
    /// rewriting it into temporary strips. This keeps HatchPet's final v2
    /// atlas as the single source of truth while letting Mimo preview each
    /// semantic row and the two-row 16-direction look loop independently.
    static func loadAtlas(data: Data, columns: Int, rows: Int,
                          cells: [CompanionAtlasCell],
                          semantics: CompanionFrameSemantics = .actionPoses,
                          fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        guard columns > 0, rows > 0, !cells.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return loadAtlas(
            sheet: sheet, columns: columns, rows: rows, cells: cells,
            semantics: semantics, fixedAnchorInCell: fixedAnchorInCell)
    }

    /// The decoded-sheet overload lets a preview catalog fan one HatchPet
    /// atlas out into all of its semantic rows without decoding the WebP once
    /// per menu item.
    static func loadAtlas(sheet: CGImage, columns: Int, rows: Int,
                          cells: [CompanionAtlasCell],
                          semantics: CompanionFrameSemantics = .actionPoses,
                          fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        guard columns > 0, rows > 0, !cells.isEmpty,
              sheet.width % columns == 0, sheet.height % rows == 0 else { return nil }
        let cellWidth = sheet.width / columns
        let cellHeight = sheet.height / rows
        guard fixedAnchorInCell.map({ anchor in
            anchor.x.isFinite && anchor.y.isFinite
                && (0...CGFloat(cellWidth)).contains(anchor.x)
                && (0...CGFloat(cellHeight)).contains(anchor.y)
        }) ?? true else { return nil }

        var frames: [CompanionFrame] = []
        for location in cells {
            guard (0..<rows).contains(location.row),
                  (0..<columns).contains(location.column),
                  let cell = sheet.cropping(to: CGRect(
                    x: location.column * cellWidth,
                    y: location.row * cellHeight,
                    width: cellWidth, height: cellHeight)),
                  let alpha = alphaSamples(of: cell) else { return nil }
            let bounds = opaqueBounds(alpha: alpha, width: cell.width, height: cell.height)
            guard !bounds.isEmpty else { return nil }
            frames.append(CompanionFrame(
                image: cell,
                opaqueBounds: bounds,
                anchorInCell: fixedAnchorInCell
                    ?? CGPoint(x: bounds.midX, y: bounds.maxY),
                mask: coarseMask(alpha: alpha, width: cell.width, height: cell.height)))
        }
        return CompanionSprite(
            frames: frames, cellSize: CGSize(width: cellWidth, height: cellHeight),
            semantics: semantics)
    }

    static func slice(sheet: CGImage, frameCount: Int,
                      semantics: CompanionFrameSemantics = .stages,
                      fixedAnchorInCell: CGPoint? = nil) -> CompanionSprite? {
        let cellWidth = sheet.width / frameCount
        let cellHeight = sheet.height
        guard cellWidth > 0, cellHeight > 0,
              fixedAnchorInCell.map({ anchor in
                  anchor.x.isFinite && anchor.y.isFinite
                      && (0...CGFloat(cellWidth)).contains(anchor.x)
                      && (0...CGFloat(cellHeight)).contains(anchor.y)
              }) ?? true else { return nil }

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
                anchorInCell: fixedAnchorInCell
                    ?? CGPoint(x: bounds.midX, y: bounds.maxY),
                mask: coarseMask(alpha: alpha, width: cell.width, height: cell.height)))
        }
        return CompanionSprite(frames: frames,
                               cellSize: CGSize(width: cellWidth, height: cellHeight),
                               semantics: semantics)
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
    /// The actual non-transparent artwork inside a rendered cell rect.
    /// `opaqueBounds` uses image-space y-down coordinates while `rect` uses
    /// AppKit's y-up screen coordinates.
    func visibleRect(in rect: CGRect, cellSize: CGSize) -> CGRect {
        guard cellSize.width > 0, cellSize.height > 0,
              rect.width > 0, rect.height > 0,
              !opaqueBounds.isEmpty else { return .zero }
        let scaleX = rect.width / cellSize.width
        let scaleY = rect.height / cellSize.height
        return CGRect(
            x: rect.minX + opaqueBounds.minX * scaleX,
            y: rect.maxY - opaqueBounds.maxY * scaleY,
            width: opaqueBounds.width * scaleX,
            height: opaqueBounds.height * scaleY)
    }

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

    /// Re-registers the visible silhouette, rather than the cell centre, to a
    /// boundary. Generated cells contain transparent padding; putting their
    /// ordinary feet anchor on a wall made half the familiar appear to fly out
    /// of the display even though physics had already recorded a collision.
    func rect(attachedTo surfaceID: SurfaceID, anchor: CGPoint,
              displayHeight: CGFloat, cellSize: CGSize) -> CGRect {
        var rect = rect(anchoredAt: anchor, displayHeight: displayHeight,
                        cellSize: cellSize)
        guard cellSize.height > 0 else { return rect }
        let scale = displayHeight / cellSize.height

        switch surfaceID {
        case .workAreaLeft, .windowLeft:
            rect.origin.x = anchor.x - opaqueBounds.minX * scale
        case .workAreaRight, .windowRight:
            rect.origin.x = anchor.x - opaqueBounds.maxX * scale
        case .workAreaTop, .windowBottom:
            // Image bounds are y-down. The visible top is therefore measured
            // from the cell's bottom as `cellHeight - opaque.minY`.
            rect.origin.y = anchor.y - (cellSize.height - opaqueBounds.minY) * scale
        default:
            break
        }
        return rect
    }
}
