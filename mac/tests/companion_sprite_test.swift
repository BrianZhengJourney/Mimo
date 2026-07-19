// sources: companion_geometry.swift companion_physics.swift companion_sprite.swift
import CoreGraphics
import Foundation

@main
struct CompanionSpriteTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func expectClose(_ actual: CGFloat, _ expected: CGFloat,
                            _ tolerance: CGFloat, _ label: String) {
        precondition(abs(actual - expected) <= tolerance,
                     "\(label): expected \(expected) ± \(tolerance), got \(actual)")
    }

    /// Builds an N-cell strip where each cell holds one opaque rect. Positions
    /// are given in cell coordinates, y-down, matching CoreGraphics image space.
    static func makeSheet(cell: Int, blobs: [CGRect]) -> CGImage {
        let width = cell * blobs.count
        let context = CGContext(data: nil, width: width, height: cell,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: cell))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        for (index, blob) in blobs.enumerated() {
            // Caller thinks y-down; CGContext draws y-up.
            let flipped = CGRect(x: CGFloat(index * cell) + blob.minX,
                                 y: CGFloat(cell) - blob.maxY,
                                 width: blob.width, height: blob.height)
            context.fill(flipped)
        }
        return context.makeImage()!
    }

    // MARK: - Slicing and bounds

    static func testSlicingFindsOpaqueBounds() {
        // A 64px cell whose art occupies x 20..40, y 10..50 — deliberately not
        // centred and not touching the cell edges.
        let sheet = makeSheet(cell: 64, blobs: [CGRect(x: 20, y: 10, width: 20, height: 40)])
        guard let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1) else {
            preconditionFailure("slice failed")
        }
        expect(sprite.frameCount == 1, "one cell in, one frame out")
        expect(sprite.cellSize == CGSize(width: 64, height: 64), "cell size preserved")

        let bounds = sprite.frame(0).opaqueBounds
        expectClose(bounds.minX, 20, 1, "left edge of art")
        expectClose(bounds.maxX, 40, 1, "right edge of art")
        expectClose(bounds.minY, 10, 1, "top edge of art")
        expectClose(bounds.maxY, 50, 1, "bottom edge of art")
    }

    /// The anchor must come from the artwork, not the cell. Cells carry uneven
    /// padding, so anchoring to the cell makes a familiar hover or sink
    /// depending on how the generator framed it.
    static func testAnchorIsFeetOfArtNotCentreOfCell() {
        let sheet = makeSheet(cell: 64, blobs: [CGRect(x: 20, y: 10, width: 20, height: 40)])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1)!
        let anchor = sprite.frame(0).anchorInCell

        expectClose(anchor.x, 30, 1, "anchor x is the art's horizontal middle")
        expectClose(anchor.y, 50, 1, "anchor y is the art's bottom, not the cell's")
        expect(abs(anchor.y - 64) > 10, "anchor must not be the cell bottom")
        expect(abs(anchor.x - 32) > 1, "anchor must not be the cell centre")
    }

    static func testMultipleCellsSliceIndependently() {
        let sheet = makeSheet(cell: 32, blobs: [
            CGRect(x: 4, y: 4, width: 8, height: 8),
            CGRect(x: 16, y: 12, width: 12, height: 16),
            CGRect(x: 8, y: 2, width: 16, height: 28),
        ])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 3)!
        expect(sprite.frameCount == 3, "three cells")
        expectClose(sprite.frame(0).anchorInCell.y, 12, 1, "frame 0 feet")
        expectClose(sprite.frame(1).anchorInCell.y, 28, 1, "frame 1 feet")
        expectClose(sprite.frame(2).anchorInCell.y, 30, 1, "frame 2 feet")
        expectClose(sprite.frame(1).anchorInCell.x, 22, 1, "frame 1 centre")
    }

    /// A blank cell has no derivable anchor. Failing the load is right — the
    /// alternative is a familiar rendering at a nonsense position.
    static func testEmptyCellIsRejected() {
        let sheet = makeSheet(cell: 32, blobs: [CGRect(x: 4, y: 4, width: 8, height: 8),
                                                CGRect.zero])
        expect(CompanionSprite.slice(sheet: sheet, frameCount: 2) == nil,
               "an empty cell must fail the load, not produce a broken frame")
    }

    static func testFrameIndexIsClamped() {
        let sheet = makeSheet(cell: 32, blobs: [CGRect(x: 4, y: 4, width: 8, height: 8)])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1)!
        // Expression indices come from JS state; an out-of-range one should pin
        // to a real frame rather than trap.
        _ = sprite.frame(9)
        _ = sprite.frame(-3)
    }

    // MARK: - Anchoring on screen

    /// The feet must land exactly on the anchor at any render size, or a
    /// familiar standing on the work-area floor visibly floats above it.
    static func testRectPutsFeetOnTheAnchor() {
        let sheet = makeSheet(cell: 64, blobs: [CGRect(x: 20, y: 10, width: 20, height: 40)])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1)!
        let frame = sprite.frame(0)
        let anchor = CGPoint(x: 500, y: 300)

        for displayHeight in [CGFloat(64), 128, 240] {
            let rect = frame.rect(anchoredAt: anchor, displayHeight: displayHeight,
                                  cellSize: sprite.cellSize)
            let scale = displayHeight / sprite.cellSize.height

            expectClose(rect.height, displayHeight, 0.01, "cell scales to the requested height")
            // Art bottom sits 14px above the cell bottom (64 - 50), scaled.
            let artBottomOnScreen = rect.minY + (sprite.cellSize.height - frame.anchorInCell.y) * scale
            expectClose(artBottomOnScreen, anchor.y, 0.01,
                        "feet land on the anchor at height \(displayHeight)")
            let artCentreOnScreen = rect.minX + frame.anchorInCell.x * scale
            expectClose(artCentreOnScreen, anchor.x, 0.01,
                        "art centres on the anchor at height \(displayHeight)")
        }
    }

    // MARK: - Hit testing

    static func testHitMaskFollowsTheArtwork() {
        // Art in the lower-right quadrant only.
        let sheet = makeSheet(cell: 64, blobs: [CGRect(x: 32, y: 32, width: 32, height: 32)])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1)!
        let frame = sprite.frame(0)
        let rect = CGRect(x: 100, y: 100, width: 64, height: 64)

        // Screen space is y-up, so the art's lower-right in image space is the
        // rect's lower-right here too.
        expect(frame.isOpaque(at: CGPoint(x: 148, y: 116), in: rect),
               "a point on the artwork should hit")
        expect(!frame.isOpaque(at: CGPoint(x: 116, y: 148), in: rect),
               "the empty upper-left quadrant should miss")
        expect(!frame.isOpaque(at: CGPoint(x: 116, y: 116), in: rect),
               "the empty lower-left quadrant should miss")
    }

    /// This is the behaviour the hardcoded 260x265 rectangle in main.swift got
    /// wrong in both directions: it swallowed clicks in empty space beside the
    /// familiar and missed thin parts of it.
    static func testHitMaskRejectsEmptySpaceInsideTheRect() {
        // A narrow vertical bar: most of the bounding rect is empty.
        let sheet = makeSheet(cell: 64, blobs: [CGRect(x: 28, y: 0, width: 8, height: 64)])
        let sprite = CompanionSprite.slice(sheet: sheet, frameCount: 1)!
        let frame = sprite.frame(0)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)

        expect(frame.isOpaque(at: CGPoint(x: 32, y: 32), in: rect), "the bar itself hits")
        expect(!frame.isOpaque(at: CGPoint(x: 6, y: 32), in: rect),
               "empty space left of the bar must fall through to the window below")
        expect(!frame.isOpaque(at: CGPoint(x: 58, y: 32), in: rect),
               "empty space right of the bar must fall through")
    }

    static func testHitTestOutsideRectIsAlwaysMiss() {
        let sheet = makeSheet(cell: 32, blobs: [CGRect(x: 0, y: 0, width: 32, height: 32)])
        let frame = CompanionSprite.slice(sheet: sheet, frameCount: 1)!.frame(0)
        let rect = CGRect(x: 100, y: 100, width: 32, height: 32)
        expect(!frame.isOpaque(at: CGPoint(x: 50, y: 110), in: rect), "left of the rect")
        expect(!frame.isOpaque(at: CGPoint(x: 200, y: 110), in: rect), "right of the rect")
        expect(!frame.isOpaque(at: .zero, in: .zero), "a degenerate rect never hits")
    }

    static func main() {
        testSlicingFindsOpaqueBounds()
        testAnchorIsFeetOfArtNotCentreOfCell()
        testMultipleCellsSliceIndependently()
        testEmptyCellIsRejected()
        testFrameIndexIsClamped()
        testRectPutsFeetOnTheAnchor()
        testHitMaskFollowsTheArtwork()
        testHitMaskRejectsEmptySpaceInsideTheRect()
        testHitTestOutsideRectIsAlwaysMiss()
        print("companion sprite: all assertions passed")
    }
}
