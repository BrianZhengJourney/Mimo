// sources: pet_provider.swift pet_generation.swift custom_pet.swift character_sheet.swift generation_draft.swift generation_ledger.swift style_reference.swift reference_preprocessor.swift
import Foundation

@main
struct PetProviderTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func spec(size: PetPixelSize = .landscape1536,
                     references: [PetProviderReference]? = nil,
                     delivery: PetGenerationDelivery = .blocking,
                     transparent: Bool = false) -> PetImageRequestSpec {
        PetImageRequestSpec(
            references: references ?? [
                PetProviderReference(filename: "identity-reference.png",
                                     data: Data("IDENTITY_BYTES".utf8), role: .identity),
                PetProviderReference(filename: "mimo-style-board.png",
                                     data: Data("STYLE_BYTES".utf8), role: .style),
            ],
            prompt: "PROMPT_TEXT",
            size: size,
            quality: .medium,
            delivery: delivery,
            apiKey: "KEY",
            timeout: 300,
            boundary: "BOUNDARY",
            wantsTransparentBackground: transparent)
    }

    static func openAI(_ model: String = PetOpenAIProvider.defaultModel) -> PetOpenAIProvider {
        PetOpenAIProvider(model: model, maximumBodyBytes: 40 * 1024 * 1024)
    }

    static func bodyText(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: - The refactor's acceptance criterion

    /// The multipart body moved out of pet_generation.swift into the provider.
    /// This pins the exact wire format so the move cannot have changed what the
    /// provider receives — the whole point of doing it as a pure refactor.
    static func testOpenAIMultipartBodyIsUnchanged() throws {
        let request = try openAI().buildRequest(spec())
        let body = bodyText(request)

        let expected = [
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-image-2\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"size\"\r\n\r\n1536x1024\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"quality\"\r\n\r\nmedium\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"output_format\"\r\n\r\npng\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"background\"\r\n\r\nopaque\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"n\"\r\n\r\n1\r\n",
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nPROMPT_TEXT\r\n",
        ]
        for field in expected {
            expect(body.contains(field), "multipart body must still contain \(field.debugDescription)")
        }
        expect(body.contains("name=\"image[]\"; filename=\"identity-reference.png\""),
               "reference part header unchanged")
        expect(body.hasSuffix("--BOUNDARY--\r\n"), "closing boundary unchanged")

        expect(request.url?.absoluteString == "https://api.openai.com/v1/images/edits",
               "endpoint unchanged")
        expect(request.httpMethod == "POST", "method unchanged")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer KEY",
               "authorization unchanged")
        expect(request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=BOUNDARY", "content type unchanged")
        expect(request.value(forHTTPHeaderField: "Content-Length") == nil,
               "Content-Length stays unset; URLSession computes it")
    }

    /// Reference order is the only signal OpenAI gets about role, so callers
    /// put the identity lock first and the order must survive the mapping.
    static func testReferenceOrderIsPreserved() throws {
        let request = try openAI().buildRequest(spec())
        let body = bodyText(request)
        guard let identity = body.range(of: "identity-reference.png"),
              let style = body.range(of: "mimo-style-board.png") else {
            preconditionFailure("both references should be present")
        }
        expect(identity.lowerBound < style.lowerBound,
               "identity must precede style in the body")
    }

    static func testStreamingFieldsOnlyAppearWhenStreaming() throws {
        let blocking = bodyText(try openAI().buildRequest(spec(delivery: .blocking)))
        expect(!blocking.contains("name=\"stream\""), "blocking requests carry no stream field")

        let streaming = try openAI().buildRequest(spec(delivery: .streaming(.two)))
        let body = bodyText(streaming)
        expect(body.contains("name=\"stream\"\r\n\r\ntrue\r\n"), "stream field present")
        expect(body.contains("name=\"partial_images\"\r\n\r\n2\r\n"), "partial count present")
        expect(streaming.value(forHTTPHeaderField: "Accept") == "text/event-stream",
               "streaming sets the SSE Accept header")
    }

    // MARK: - Capabilities that are load-bearing

    /// gpt-image-2 does not support transparent backgrounds — a regression from
    /// gpt-image-1. Asking for one anyway must not produce a request the
    /// provider will reject; alpha comes from the matte instead.
    static func testGPTImage2NeverAsksForTransparency() throws {
        let request = try openAI().buildRequest(spec(transparent: true))
        expect(bodyText(request).contains("name=\"background\"\r\n\r\nopaque\r\n"),
               "gpt-image-2 must stay opaque even when transparency is requested")
        expect(!openAI().capabilities.supportsTransparentBackground,
               "and must report that it cannot do it")
    }

    static func testGPTImage1CanRequestTransparency() throws {
        let provider = openAI("gpt-image-1")
        expect(provider.capabilities.supportsTransparentBackground,
               "gpt-image-1 does support transparency")
        let request = try provider.buildRequest(spec(size: .square1024, transparent: true))
        expect(bodyText(request).contains("name=\"background\"\r\n\r\ntransparent\r\n"),
               "and honours the request")
    }

    /// Neither backend exposes a seed. This is not a detail — it is why
    /// consistency has to be measured after generation instead of guaranteed.
    static func testNeitherProviderClaimsASeed() {
        expect(!openAI().capabilities.supportsSeed, "OpenAI has no seed parameter")
        expect(!PetGeminiProvider(maximumBodyBytes: 1024).capabilities.supportsSeed,
               "Gemini has no seed parameter")
    }

    static func testGeminiDeclaresItsTradeoffs() {
        let gemini = PetGeminiProvider(maximumBodyBytes: 1024)
        expect(gemini.capabilities.hasTypedCharacterReference,
               "typed character references are Gemini's structural advantage")
        expect(gemini.capabilities.watermarksOutput,
               "SynthID is unconditional and must be surfaced to the user")
        expect(!gemini.capabilities.supportsTransparentBackground, "no native alpha")
    }

    // MARK: - Size rules

    /// 2048x2048 is legal on gpt-image-2 and not on gpt-image-1. Per-cell
    /// resolution is the binding constraint on contact-sheet quality, so this
    /// is the difference that makes a nine-frame action sheet worth generating.
    static func testActionSheetSizeIsGPTImage2Only() throws {
        _ = try openAI().buildRequest(spec(size: .square2048))

        var rejected = false
        do { _ = try openAI("gpt-image-1").buildRequest(spec(size: .square2048)) }
        catch { rejected = true }
        expect(rejected, "gpt-image-1 must reject 2048x2048 rather than send it")
    }

    static func testSizeRuleEnforcesEveryDocumentedConstraint() {
        let rule = PetSizeRule.openAIGPTImage2
        expect(rule.accepts(.square1536), "1536x1536 satisfies every constraint")
        expect(rule.accepts(.square2048), "2048x2048 satisfies every constraint")
        expect(!rule.accepts(PetPixelSize(width: 4096, height: 1024)),
               "over the 3840 max edge")
        expect(!rule.accepts(PetPixelSize(width: 1000, height: 1000)),
               "1000 is not a multiple of 16")
        expect(!rule.accepts(PetPixelSize(width: 3840, height: 1024)),
               "3.75:1 is more lopsided than 3:1")
        expect(!rule.accepts(PetPixelSize(width: 512, height: 512)),
               "under the minimum pixel count")
        expect(!rule.accepts(PetPixelSize(width: 3840, height: 2176)),
               "over the maximum pixel count")
    }

    /// A refusal has to say what is wrong, or a size mistake shows up as a
    /// silent nil from the request builder.
    static func testRejectionExplainsItself() {
        let rule = PetSizeRule.openAIGPTImage2
        expect(rule.rejection(.square2048) == nil, "a legal size has no complaint")
        let complaint = rule.rejection(PetPixelSize(width: 1000, height: 1000)) ?? ""
        expect(complaint.contains("multiple of 16"), "names the actual violation, got '\(complaint)'")
    }

    // MARK: - Shared preflight

    static func testEmptyReferencesAreRejected() {
        var rejected = false
        do { _ = try openAI().buildRequest(spec(references: [])) } catch { rejected = true }
        expect(rejected, "an edit with no reference must be refused")
    }

    static func testOversizedPayloadIsRejected() {
        let heavy = PetProviderReference(filename: "identity-reference.png",
                                         data: Data(count: 4096), role: .identity)
        var rejected = false
        do {
            _ = try PetOpenAIProvider(maximumBodyBytes: 1024).buildRequest(spec(references: [heavy]))
        } catch { rejected = true }
        expect(rejected, "the aggregate payload cap must be enforced before sending")
    }

    static func testTooManyReferencesAreRejected() {
        let many = (0..<20).map {
            PetProviderReference(filename: "ref\($0).png", data: Data("x".utf8), role: .identity)
        }
        var rejected = false
        do { _ = try openAI().buildRequest(spec(references: many)) } catch { rejected = true }
        expect(rejected, "reference count over the provider's limit must be refused")
    }

    // MARK: - Gemini request shape

    static func testGeminiSendsJSONWithInlineReferences() throws {
        let request = try PetGeminiProvider(maximumBodyBytes: 40 * 1024 * 1024)
            .buildRequest(spec(size: .square1024))
        expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json",
               "Gemini takes JSON, not multipart")
        expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "KEY",
               "and a different auth header")

        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            preconditionFailure("body should be a JSON object")
        }
        expect(json["model"] as? String == "gemini-3.1-flash-image", "model named")
        guard let input = json["input"] as? [[String: Any]] else {
            preconditionFailure("input array expected")
        }
        expect(input.first?["type"] as? String == "text", "prompt leads the input")
        expect(input.dropFirst().allSatisfy { $0["type"] as? String == "image" },
               "references follow as inline images")
        expect(input.dropFirst().first?["role"] as? String == "identity",
               "reference roles survive, since Gemini has typed slots")

        guard let format = json["response_format"] as? [String: Any] else {
            preconditionFailure("response_format expected")
        }
        expect(format["aspect_ratio"] as? String == "1:1", "square maps to 1:1")
        expect(format["image_size"] as? String == "1K", "1024 maps to the 1K bucket")
    }

    static func testGeminiMapsSizesOntoBuckets() {
        expect(PetGeminiProvider.imageSizeBucket(for: .square1024) == "1K", "1024 → 1K")
        expect(PetGeminiProvider.imageSizeBucket(for: .square2048) == "2K", "2048 → 2K")
        expect(PetGeminiProvider.imageSizeBucket(for: PetPixelSize(width: 512, height: 512)) == "512px",
               "512 → 512px")
        expect(PetGeminiProvider.aspectRatio(for: .landscape1536) == "3:2",
               "1536x1024 is 3:2")
    }

    // MARK: - Role inference

    static func testOutputSizeBridgesToPixelSize() {
        expect(PetImageOutputSize.square.pixelSize == .square1024, "square bridges")
        expect(PetImageOutputSize.landscape.pixelSize == .landscape1536, "landscape bridges")
        expect(PetImageOutputSize.actionSheet.pixelSize == .square2048, "action sheet bridges")
    }

    static func main() throws {
        try testOpenAIMultipartBodyIsUnchanged()
        try testReferenceOrderIsPreserved()
        try testStreamingFieldsOnlyAppearWhenStreaming()
        try testGPTImage2NeverAsksForTransparency()
        try testGPTImage1CanRequestTransparency()
        testNeitherProviderClaimsASeed()
        testGeminiDeclaresItsTradeoffs()
        try testActionSheetSizeIsGPTImage2Only()
        testSizeRuleEnforcesEveryDocumentedConstraint()
        testRejectionExplainsItself()
        testEmptyReferencesAreRejected()
        testOversizedPayloadIsRejected()
        testTooManyReferencesAreRejected()
        try testGeminiSendsJSONWithInlineReferences()
        testGeminiMapsSizesOntoBuckets()
        testOutputSizeBridgesToPixelSize()
        print("pet provider: all assertions passed")
    }
}
