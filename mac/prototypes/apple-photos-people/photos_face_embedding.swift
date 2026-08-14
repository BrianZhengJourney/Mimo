// THROWAWAY PROTOTYPE — Core ML face embedding adapter for Photos A/B.

import CoreGraphics
import CoreML
import CoreVideo
import Foundation

struct PhotosFaceEmbeddingPrediction {
    let embedding: PhotosFaceIdentityEmbedding
    let milliseconds: Double
}

final class PhotosFaceEmbeddingRuntime {
    private let ir101: MLModel?
    private let kprpe: MLModel?

    init(bundle: Bundle = .main) {
        ir101 = Self.load("MimoAdaFaceIR101", bundle: bundle)
        kprpe = Self.load("MimoAdaFaceKPRPE", bundle: bundle)
    }

    func isAvailable(_ model: PhotosFaceIdentityModel) -> Bool {
        switch model {
        case .vision: return true
        case .ir101: return ir101 != nil
        case .kprpe: return kprpe != nil
        }
    }

    func predictIR101(_ image: CGImage) -> PhotosFaceEmbeddingPrediction? {
        guard let ir101, let buffer = pixelBuffer(from: image) else { return nil }
        return predict(model: ir101, values: [
            "face": MLFeatureValue(pixelBuffer: buffer),
        ])
    }

    func predictKPRPE(
        _ image: CGImage, keypoints: [Float]
    ) -> PhotosFaceEmbeddingPrediction? {
        guard let kprpe, keypoints.count == 10,
              let buffer = pixelBuffer(from: image),
              let landmarks = try? MLMultiArray(
                shape: [1, 5, 2], dataType: .float32) else { return nil }
        for index in keypoints.indices {
            landmarks[index] = NSNumber(value: keypoints[index])
        }
        return predict(model: kprpe, values: [
            "face": MLFeatureValue(pixelBuffer: buffer),
            "keypoints": MLFeatureValue(multiArray: landmarks),
        ])
    }

    private func predict(
        model: MLModel, values: [String: MLFeatureValue]
    ) -> PhotosFaceEmbeddingPrediction? {
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: values) else {
            return nil
        }
        let started = CFAbsoluteTimeGetCurrent()
        guard let features = try? model.prediction(from: provider),
              let array = features.featureValue(for: "embedding")?.multiArrayValue,
              array.count > 0 else { return nil }
        var raw = [Float]()
        raw.reserveCapacity(array.count)
        for index in 0..<array.count { raw.append(Float(truncating: array[index])) }
        let norm = sqrt(raw.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        let unit = raw.map { $0 / norm }
        return PhotosFaceEmbeddingPrediction(
            embedding: PhotosFaceIdentityEmbedding(vector: unit, rawNorm: norm),
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000)
    }

    private static func load(_ name: String, bundle: Bundle) -> MLModel? {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = 112, height = 112
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
