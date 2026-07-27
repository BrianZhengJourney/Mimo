// Mimo — bundled, hidden family-language reference for GPT Image requests.

import Cocoa
import Foundation

enum MimoStyleReference {
    static let resourceSubdirectory = "style-reference"
    static let filename = "mimo-style-reference-board.png"
    static let expectedWidth = 1536
    static let expectedHeight = 1024
    static let maximumBytes = 8 * 1024 * 1024
    static let requestWidth = 768
    static let requestHeight = 512
    private static let cacheLock = NSLock()
    private static var requestCache: [URL: Data] = [:]

    static func bundledData(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "mimo-style-reference-board",
                                   withExtension: "png",
                                   subdirectory: resourceSubdirectory),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              isValid(data) else { return nil }
        return data
    }

    /// The full board is kept as the design-system source of truth. Requests
    /// use a half-size copy: it preserves the chunky pixel language while
    /// reducing upload bytes and the provider's reference-image token work.
    static func requestData(bundle: Bundle = .main) -> Data? {
        let cacheKey = bundle.bundleURL.standardizedFileURL
        cacheLock.lock()
        let cached = requestCache[cacheKey]
        cacheLock.unlock()
        if let cached { return cached }
        guard let sourceData = bundledData(bundle: bundle),
              let png = requestData(masterData: sourceData) else { return nil }
        cacheLock.lock(); requestCache[cacheKey] = png; cacheLock.unlock()
        return png
    }

    static func requestData(masterData: Data) -> Data? {
        guard isValid(masterData), let source = NSImage(data: masterData) else { return nil }
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: requestWidth, pixelsHigh: requestHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        guard let representation,
              let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = NSImageInterpolation.none
        source.draw(in: NSRect(x: 0, y: 0, width: requestWidth, height: requestHeight),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = representation.representation(
            using: NSBitmapImageRep.FileType.png, properties: [:]) else { return nil }
        return png
    }

    /// Validates the PNG signature and IHDR without decoding a multi-megapixel
    /// bitmap on the AppKit main thread.
    static func isValid(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard data.count >= 24, data.count <= maximumBytes,
              data.starts(with: signature),
              String(bytes: data[12..<16], encoding: .ascii) == "IHDR" else { return false }
        func integer(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return integer(at: 16) == expectedWidth && integer(at: 20) == expectedHeight
    }
}

/// A pose-only timing reference. It is deliberately a plain skeleton rather
/// than generated character art: the model should borrow joint order without
/// finding a second identity to blend into the locked Mimo character.
enum MimoMotionReference {
    static let resourceSubdirectory = "motion-reference"
    static let walkFilename = "biped-walk-cycle-16"
    static let walkInbetweenFilename = "biped-walk-inbetweens-16"
    static let expectedWidth = 960
    static let expectedHeight = 960
    static let maximumBytes = 2 * 1024 * 1024

    static func requestData(for action: String, bundle: Bundle = .main) -> Data? {
        guard action == "walk",
              let url = bundle.url(forResource: walkFilename, withExtension: "png",
                                   subdirectory: resourceSubdirectory),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              isValid(data) else { return nil }
        return data
    }

    static func walkInbetweenData(bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: walkInbetweenFilename, withExtension: "png",
                                   subdirectory: resourceSubdirectory),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              isValid(data) else { return nil }
        return data
    }

    static func isValid(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard data.count >= 24, data.count <= maximumBytes,
              data.starts(with: signature),
              String(bytes: data[12..<16], encoding: .ascii) == "IHDR" else { return false }
        func integer(at offset: Int) -> Int {
            data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        return integer(at: 16) == expectedWidth && integer(at: 20) == expectedHeight
    }
}
