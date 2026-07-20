import Foundation

// The image-generation backend, behind an interface.
//
// The model id and endpoint used to be hardcoded inside the multipart builder,
// which made "try another provider" a code edit. It is not a one-line change
// either: the two candidate backends differ in request *shape*, not just in a
// model string — multipart against JSON, untyped references against typed
// slots, explicit pixel sizes against aspect-ratio buckets. See
// docs/companion/04-generation-and-consistency.md §4.8.
//
// The seam sits below the coordinator, so artifacts, prompts, the spend ledger
// and draft retention stay backend-agnostic. Facts here were verified against
// vendor documentation on 2026-07-18; the citations live in §4.9.

extension Data {
    /// Multipart bodies are assembled byte-wise; this keeps that readable.
    /// Lives here rather than in pet_generation.swift because the multipart
    /// writer is now the provider's business.
    mutating func appendUTF8(_ string: String) { append(Data(string.utf8)) }
}

// MARK: - Sizes

struct PetPixelSize: Equatable, CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)x\(height)" }
    var pixels: Int { width * height }
    var aspectRatio: Double {
        let long = Double(max(width, height)), short = Double(min(width, height))
        return short > 0 ? long / short : .infinity
    }

    static let square1024 = PetPixelSize(width: 1024, height: 1024)
    static let landscape1536 = PetPixelSize(width: 1536, height: 1024)
    static let square1536 = PetPixelSize(width: 1536, height: 1536)
    static let square2048 = PetPixelSize(width: 2048, height: 2048)
}

/// What sizes a backend will accept.
///
/// Modelled as a rule rather than a fixed list because gpt-image-2 takes
/// essentially arbitrary resolutions within constraints, while Gemini takes
/// aspect-ratio plus a size bucket. A two-value enum — which is what this
/// replaced — is a gpt-image-1-era limit that leaves a lot of resolution on the
/// table, and per-cell resolution is the binding constraint on contact-sheet
/// quality.
struct PetSizeRule {
    let maxEdge: Int
    let edgeMultiple: Int
    let maxAspectRatio: Double
    let minPixels: Int
    let maxPixels: Int
    /// When non-nil, only these exact sizes are legal.
    let allowedSizes: [PetPixelSize]?

    func accepts(_ size: PetPixelSize) -> Bool {
        if let allowedSizes { return allowedSizes.contains(size) }
        guard size.width > 0, size.height > 0 else { return false }
        guard max(size.width, size.height) <= maxEdge else { return false }
        guard size.width % edgeMultiple == 0, size.height % edgeMultiple == 0 else { return false }
        guard size.aspectRatio <= maxAspectRatio else { return false }
        return size.pixels >= minPixels && size.pixels <= maxPixels
    }

    /// Why a size was refused, for an error a person can act on.
    func rejection(_ size: PetPixelSize) -> String? {
        guard !accepts(size) else { return nil }
        if let allowedSizes {
            return "\(size) is not one of \(allowedSizes.map(\.description).joined(separator: ", "))"
        }
        if size.width <= 0 || size.height <= 0 { return "\(size) has a non-positive edge" }
        if max(size.width, size.height) > maxEdge {
            return "\(size) exceeds the \(maxEdge)px maximum edge"
        }
        if size.width % edgeMultiple != 0 || size.height % edgeMultiple != 0 {
            return "\(size) has an edge that is not a multiple of \(edgeMultiple)"
        }
        if size.aspectRatio > maxAspectRatio {
            return "\(size) is more lopsided than \(Int(maxAspectRatio)):1"
        }
        if size.pixels < minPixels { return "\(size) is under the \(minPixels) pixel minimum" }
        return "\(size) is over the \(maxPixels) pixel maximum"
    }

    /// gpt-image-2, verified: edge ≤ 3840, both edges multiples of 16, long:short
    /// ≤ 3:1, total pixels in [655360, 8294400].
    static let openAIGPTImage2 = PetSizeRule(
        maxEdge: 3840, edgeMultiple: 16, maxAspectRatio: 3,
        minPixels: 655_360, maxPixels: 8_294_400, allowedSizes: nil)

    /// gpt-image-1 / 1.5 take a fixed set; 1536x1536 is NOT among them.
    static let openAIGPTImage1 = PetSizeRule(
        maxEdge: 1536, edgeMultiple: 16, maxAspectRatio: 3,
        minPixels: 0, maxPixels: .max,
        allowedSizes: [.square1024, .landscape1536, PetPixelSize(width: 1024, height: 1536)])
}

// MARK: - Capabilities

/// How a reference image is meant to be used.
///
/// OpenAI takes an undifferentiated list, so the role is dropped there. Gemini
/// has typed slots with a distinct character-reference category, which is a real
/// structural advantage for a locked-character pipeline — flattening every
/// reference to "an image" would throw it away.
enum PetReferenceRole: String {
    case master
    case identity
    case style
    case expression
}

struct PetProviderCapabilities {
    let supportsTransparentBackground: Bool
    let supportsStreaming: Bool
    /// Neither current backend offers one. Kept because its absence is the
    /// reason consistency has to be measured after the fact rather than
    /// guaranteed up front, and because a future backend might.
    let supportsSeed: Bool
    let maxReferenceImages: Int
    let hasTypedCharacterReference: Bool
    /// Gemini watermarks unconditionally with SynthID.
    let watermarksOutput: Bool
    let sizeRule: PetSizeRule
}

// MARK: - Request

struct PetProviderReference {
    let filename: String
    let data: Data
    let role: PetReferenceRole
}

struct PetImageRequestSpec {
    let references: [PetProviderReference]
    let prompt: String
    let size: PetPixelSize
    let quality: PetGenerationQuality
    let delivery: PetGenerationDelivery
    let apiKey: String
    let timeout: TimeInterval
    let boundary: String
    /// Requested only; a backend that cannot honour it composites from a matte.
    let wantsTransparentBackground: Bool

    init(references: [PetProviderReference], prompt: String, size: PetPixelSize,
         quality: PetGenerationQuality, delivery: PetGenerationDelivery,
         apiKey: String, timeout: TimeInterval, boundary: String,
         wantsTransparentBackground: Bool = false) {
        self.references = references
        self.prompt = prompt
        self.size = size
        self.quality = quality
        self.delivery = delivery
        self.apiKey = apiKey
        self.timeout = timeout
        self.boundary = boundary
        self.wantsTransparentBackground = wantsTransparentBackground
    }
}

enum PetProviderRejection: Error, CustomStringConvertible {
    case noReferences
    case tooManyReferences(got: Int, limit: Int)
    case referencesTooLarge(bytes: Int, limit: Int)
    case unsupportedSize(String)

    var description: String {
        switch self {
        case .noReferences: return "an edit request needs at least one reference image"
        case .tooManyReferences(let got, let limit):
            return "\(got) reference images exceeds this provider's limit of \(limit)"
        case .referencesTooLarge(let bytes, let limit):
            return "reference payload is \(bytes) bytes, over the \(limit) byte cap"
        case .unsupportedSize(let detail): return detail
        }
    }
}

protocol PetImageProvider {
    var id: String { get }
    var capabilities: PetProviderCapabilities { get }
    func buildRequest(_ spec: PetImageRequestSpec) throws -> URLRequest
    /// Parses one streamed event, or nil if this backend has no streaming.
    func streamEvent(jsonData: Data) -> PetImageStreamEvent?
}

extension PetImageProvider {
    /// Shared preflight. Kept here so a new backend cannot forget it: an
    /// unchecked aggregate once meant a ~160MB transient peak and a 413.
    func validate(_ spec: PetImageRequestSpec, maximumBodyBytes: Int) throws {
        guard !spec.references.isEmpty else { throw PetProviderRejection.noReferences }
        guard spec.references.count <= capabilities.maxReferenceImages else {
            throw PetProviderRejection.tooManyReferences(
                got: spec.references.count, limit: capabilities.maxReferenceImages)
        }
        let bytes = spec.references.reduce(0) { $0 + $1.data.count }
        guard bytes <= maximumBodyBytes else {
            throw PetProviderRejection.referencesTooLarge(bytes: bytes, limit: maximumBodyBytes)
        }
        if let rejection = capabilities.sizeRule.rejection(spec.size) {
            throw PetProviderRejection.unsupportedSize(rejection)
        }
    }
}

// MARK: - OpenAI

/// `POST /v1/images/edits`, multipart.
///
/// Two verified details worth keeping in view. The endpoint's default model is
/// `gpt-image-1.5`, not `gpt-image-2`, so naming the model explicitly is load
/// bearing. And gpt-image-2 does not support transparent backgrounds at all —
/// a regression from gpt-image-1 — which is why alpha comes from the flat matte
/// and `background` is pinned to opaque.
struct PetOpenAIProvider: PetImageProvider {
    static let defaultModel = "gpt-image-2"

    let model: String
    let maximumBodyBytes: Int

    init(model: String = PetOpenAIProvider.defaultModel,
         maximumBodyBytes: Int) {
        self.model = model
        self.maximumBodyBytes = maximumBodyBytes
    }

    var id: String { "openai.\(model)" }

    var capabilities: PetProviderCapabilities {
        let isGPTImage2 = model.hasPrefix("gpt-image-2")
        return PetProviderCapabilities(
            supportsTransparentBackground: !isGPTImage2,
            supportsStreaming: true,
            supportsSeed: false,
            // The API allows 16; the lower cap here is the app's own budget,
            // since a stage request already attaches four large PNGs.
            maxReferenceImages: 10,
            hasTypedCharacterReference: false,
            watermarksOutput: false,
            sizeRule: isGPTImage2 ? .openAIGPTImage2 : .openAIGPTImage1)
    }

    func buildRequest(_ spec: PetImageRequestSpec) throws -> URLRequest {
        try validate(spec, maximumBodyBytes: maximumBodyBytes)

        let url = URL(string: "https://api.openai.com/v1/images/edits")!
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendUTF8("--\(spec.boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        field("model", model)
        field("size", spec.size.description)
        field("quality", spec.quality.rawValue)
        field("output_format", "png")
        field("background",
              spec.wantsTransparentBackground && capabilities.supportsTransparentBackground
                ? "transparent" : "opaque")
        field("n", "1")
        field("prompt", spec.prompt)
        if case .streaming(let partialImages) = spec.delivery {
            field("stream", "true")
            field("partial_images", String(partialImages.rawValue))
        }
        // Roles are dropped: this endpoint takes an undifferentiated list and
        // order is the only signal, so callers put the identity lock first.
        for reference in spec.references {
            body.appendUTF8("--\(spec.boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"image[]\"; filename=\"\(reference.filename)\"\r\n")
            body.appendUTF8("Content-Type: image/png\r\n\r\n")
            body.append(reference.data)
            body.appendUTF8("\r\n")
        }
        body.appendUTF8("--\(spec.boundary)--\r\n")

        var request = URLRequest(url: url, timeoutInterval: spec.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(spec.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(spec.boundary)",
                         forHTTPHeaderField: "Content-Type")
        // Content-Length is reserved — URLSession computes it from httpBody.
        if case .streaming = spec.delivery {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = body
        return request
    }

    func streamEvent(jsonData: Data) -> PetImageStreamEvent? {
        PetGenerationCoordinator.imageStreamEvent(jsonData: jsonData)
    }
}

// MARK: - Gemini

/// `POST /v1beta/interactions`, JSON with inline base64.
///
/// Present so the A/B in P3c has something to compare against, and so the
/// interface is shaped by two real backends rather than one. Two things it does
/// that OpenAI cannot: typed character references, and a batch tier at half
/// price. Two it does worse: no alpha, and an unconditional SynthID watermark.
struct PetGeminiProvider: PetImageProvider {
    static let defaultModel = "gemini-3.1-flash-image"

    let model: String
    let maximumBodyBytes: Int

    init(model: String = PetGeminiProvider.defaultModel, maximumBodyBytes: Int) {
        self.model = model
        self.maximumBodyBytes = maximumBodyBytes
    }

    var id: String { "google.\(model)" }

    var capabilities: PetProviderCapabilities {
        PetProviderCapabilities(
            supportsTransparentBackground: false,
            supportsStreaming: false,
            supportsSeed: false,
            // Documented as 14 total across all reference categories. The
            // per-category split could not be confirmed — two fetches of the
            // same page disagreed — so only the total is relied on here.
            maxReferenceImages: 14,
            hasTypedCharacterReference: true,
            watermarksOutput: true,
            sizeRule: PetSizeRule(maxEdge: 4096, edgeMultiple: 1, maxAspectRatio: 3,
                                  minPixels: 0, maxPixels: 16_777_216, allowedSizes: nil))
    }

    /// Maps a pixel size onto the nearest documented bucket.
    static func imageSizeBucket(for size: PetPixelSize) -> String {
        let longEdge = max(size.width, size.height)
        if longEdge <= 512 { return "512px" }
        if longEdge <= 1024 { return "1K" }
        if longEdge <= 2048 { return "2K" }
        return "4K"
    }

    /// Nearest documented aspect ratio, since this backend takes a ratio rather
    /// than explicit pixels.
    static func aspectRatio(for size: PetPixelSize) -> String {
        let ratios: [(String, Double)] = [
            ("1:1", 1), ("3:2", 1.5), ("2:3", 2.0 / 3), ("3:4", 0.75), ("4:3", 4.0 / 3),
            ("4:5", 0.8), ("5:4", 1.25), ("9:16", 0.5625), ("16:9", 16.0 / 9), ("21:9", 21.0 / 9),
        ]
        let actual = Double(size.width) / Double(size.height)
        return ratios.min { abs($0.1 - actual) < abs($1.1 - actual) }?.0 ?? "1:1"
    }

    func buildRequest(_ spec: PetImageRequestSpec) throws -> URLRequest {
        try validate(spec, maximumBodyBytes: maximumBodyBytes)

        var input: [[String: Any]] = [["type": "text", "text": spec.prompt]]
        for reference in spec.references {
            input.append([
                "type": "image",
                "mime_type": "image/png",
                "data": reference.data.base64EncodedString(),
                // Carried even though the shape is not final: dropping it here
                // would discard the one structural advantage this backend has.
                "role": reference.role.rawValue,
            ])
        }
        let payload: [String: Any] = [
            "model": model,
            "input": input,
            "response_format": [
                "type": "image",
                "mime_type": "image/png",
                "aspect_ratio": Self.aspectRatio(for: spec.size),
                "image_size": Self.imageSizeBucket(for: spec.size),
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw PetProviderRejection.unsupportedSize("could not encode the request payload")
        }

        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
            timeoutInterval: spec.timeout)
        request.httpMethod = "POST"
        request.setValue(spec.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// No documented streaming on this endpoint, so nothing to parse.
    func streamEvent(jsonData: Data) -> PetImageStreamEvent? { nil }
}
