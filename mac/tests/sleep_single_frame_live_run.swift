// sources: pet_provider.swift custom_pet.swift character_sheet.swift action_sheet.swift consistency_metric.swift action_sheet_run.swift style_reference.swift pet_generation.swift
// compile-only: paid 16-call single-frame sleep experiment; never run unattended
//
// One immutable identity image + one identity-free pose silhouette are sent for
// each frame. No generated frame is ever used as the next frame's reference:
// the experiment measures independent-call identity drift without allowing an
// autoregressive chain to accumulate it.
//
// Run from the repository root after `./mac/test.sh sleep_single_frame`:
//   sleep_single_frame_live_run --preflight REFERENCE POSE_STRIP
//   sleep_single_frame_live_run --confirm-paid OUTPUT_DIR REFERENCE POSE_STRIP STYLE_BOARD

import AppKit
import Foundation

private enum SleepSingleFrameError: LocalizedError {
    case usage
    case missingAPIKey
    case missingInput(String)
    case invalidPoseStrip
    case invalidResponse(String)
    case incompleteFrames([Int])

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            Usage:
              sleep_single_frame_live_run --preflight REFERENCE POSE_STRIP
              sleep_single_frame_live_run --confirm-paid OUTPUT_DIR REFERENCE POSE_STRIP STYLE_BOARD
              sleep_single_frame_live_run --preflight-walk REFERENCE WALK_GUIDE
              sleep_single_frame_live_run --confirm-paid-walk OUTPUT_DIR REFERENCE WALK_GUIDE STYLE_BOARD
            """
        case .missingAPIKey:
            return "OpenAI API key is not configured in the environment or Mimo keychain."
        case .missingInput(let path):
            return "Input is missing or unreadable: \(path)"
        case .invalidPoseStrip:
            return "Pose strip must contain at least sixteen square transparent cells."
        case .invalidResponse(let message):
            return message
        case .incompleteFrames(let indices):
            return "Generation did not produce every frame; missing \(indices.map(String.init).joined(separator: ", "))."
        }
    }
}

private struct GeneratedSleepFrame {
    let index: Int
    let pngData: Data
    let usage: [String: Any]
    let requestID: String
}

private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private func input(_ path: String) throws -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
        throw SleepSingleFrameError.missingInput(path)
    }
    return data
}

@discardableResult
private func write(_ data: Data, named name: String, to directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name, isDirectory: false)
    try data.write(to: url, options: [.atomic])
    log("artifact  \(name)  \(data.count) bytes")
    return url
}

private func poseGuides(from stripData: Data) throws -> [Data] {
    let strip = try CharacterSheetProcessor.decodePNG(stripData)
    guard strip.height > 0, strip.width % strip.height == 0,
          strip.width / strip.height >= PetActionSheetPlan.rest.panels.count else {
        throw SleepSingleFrameError.invalidPoseStrip
    }
    return try PetActionSheetPlan.rest.panels.indices.map { index in
        let cell = ActionSheetProcessor.crop(
            strip, x: index * strip.height, y: 0,
            width: strip.height, height: strip.height)
        var silhouette = CharacterSheetRGBAImage(
            width: cell.width, height: cell.height,
            fill: (241, 236, 226, 255))
        for pixel in stride(from: 0, to: cell.pixels.count, by: 4) {
            guard cell.pixels[pixel + 3] > 12 else { continue }
            silhouette.pixels[pixel] = 54
            silhouette.pixels[pixel + 1] = 58
            silhouette.pixels[pixel + 2] = 70
            silhouette.pixels[pixel + 3] = 255
        }
        return try CharacterSheetProcessor.encodePNG(silhouette)
    }
}

private func walkPoseGuides(from gridData: Data) throws -> [Data] {
    let grid = try CharacterSheetProcessor.decodePNG(gridData)
    guard grid.width > 0, grid.width == grid.height,
          grid.width % 4 == 0 else {
        throw SleepSingleFrameError.invalidPoseStrip
    }
    let cellSize = grid.width / 4
    return try (0..<16).map { index in
        let cell = ActionSheetProcessor.crop(
            grid, x: (index % 4) * cellSize, y: (index / 4) * cellSize,
            width: cellSize, height: cellSize)
        return try CharacterSheetProcessor.encodePNG(cell)
    }
}

private func framePrompt(index: Int, hasStyleBoard: Bool) -> String {
    let styleReference = hasStyleBoard
        ? "Image 3 is Mimo's STYLE BOARD. Borrow only its pixel-inspired rendering language."
        : "No separate style board is supplied; preserve Image 1's rendering language exactly."
    let pose = PetActionSheetPlan.rest.panels[index]
    return """
    MIMO SINGLE-FRAME SLEEP EXPERIMENT — FRAME \(String(format: "%02d", index + 1)) OF 16

    Image 1 is the absolute IDENTITY LOCK. Preserve the exact same individual: face structure, hair, skin tone,
    body proportions, white outfit, black watch and bracelets, arm tattoo, palette, outline weight, and shading.
    Image 2 is an IDENTITY-FREE POSE SILHOUETTE. Copy only its body pose, facing direction, footprint, and framing.
    Never copy its gray color. \(styleReference)

    Draw exactly ONE complete character and nothing else except the requested dream bubble when the pose calls for
    one. This request produces one animation frame, not a contact sheet. No grid, panels, labels, numbers, captions,
    arrows, duplicate bodies, motion trails, or alternate poses.

    TARGET POSE
    \(pose).

    Keep a fixed camera in three-quarter view facing toward the LEFT. Match Image 2's scale and registration. Keep
    the complete silhouette inside the canvas with at least 64 pixels of empty background on every side. The lowest
    body point rests on one invisible horizontal ground line 96 pixels above the bottom; draw no ground or shadow.
    Preserve every identity detail even when the body turns or lies down. This must look like Image 1 physically
    moving, never a redesign, wardrobe change, age change, or new drawing interpretation.

    Premium handcrafted pixel-inspired sprite art readable at 140–220 px tall: crisp stepped edges, restrained
    dark-cocoa outline, coherent 10–14 color palette, warm selective shading, stable light from upper left.

    Use one flat opaque background of exact color #F1ECE2. No gradient, texture, floor, cast shadow, halo, glow,
    particles, scenery, furniture, frame, UI, logo, watermark, or cropped limbs.
    """
}

private func walkFramePrompt(index: Int, hasStyleBoard: Bool) -> String {
    let styleReference = hasStyleBoard
        ? "Image 3 is Mimo's STYLE BOARD. Borrow only its pixel-inspired rendering language."
        : "No separate style board is supplied; preserve Image 1's rendering language exactly."
    let pose = PetActionSheetPlan.walkCycle.panels[index]
    return """
    MIMO SINGLE-FRAME WALK EXPERIMENT — FRAME \(String(format: "%02d", index + 1)) OF 16

    Image 1 is the absolute IDENTITY LOCK. Preserve the exact same individual: face structure, hair, skin tone,
    body proportions, white outfit, black watch and bracelets, arm tattoo, palette, outline weight, and shading.
    Image 2 is an IDENTITY-FREE WALK POSE DIAGRAM. Copy only its gait phase, left/right limb positions, facing
    direction, weight distribution, footprint, and framing. Ignore its labels, arrows, lines, and colors.
    \(styleReference)

    Draw exactly ONE complete character and nothing else. This request produces one animation frame, not a contact
    sheet. No grid, panels, labels, numbers, captions, arrows, duplicate bodies, motion trails, alternate poses,
    floor line, or shadow.

    TARGET GAIT PHASE
    \(pose).

    Clean fixed-camera near-profile from the character's RIGHT side, walking toward the LEFT. Match Image 2's gait
    phase precisely while keeping Image 1's identity. Preserve left/right limb identity; never swap, merge, add, or
    lose a limb. Natural arm counter-swing. Keep the pelvis, torso scale, head scale, camera, and registration fixed
    across the cycle. The complete standing character occupies about two thirds of the canvas height.

    Both feet relate to one invisible horizontal ground line exactly 96 pixels above the bottom. The planted foot
    touches it; a swinging foot rises only as demanded by the target phase. Keep at least 48 pixels of empty
    background at top, left, and right, and keep the bottom 96 pixels empty. Draw no ground line.

    Premium handcrafted pixel-inspired sprite art readable at 140–220 px tall: crisp stepped edges, restrained
    dark-cocoa outline, coherent 10–14 color palette, warm selective shading, stable light from upper left.

    Use one flat opaque background of exact color #F1ECE2. No gradient, texture, floor, cast shadow, halo, glow,
    particles, scenery, furniture, frame, UI, logo, watermark, or cropped limbs.
    """
}

private func providerError(_ data: Data, status: Int) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data),
       let message = PetGenerationCoordinator.providerMessage(object) {
        return "OpenAI frame request failed (HTTP \(status)): \(message)"
    }
    return "OpenAI frame request failed (HTTP \(status))."
}

private func generateFrame(index: Int,
                           actionKey: String,
                           prompt: String,
                           identity: Data,
                           poseGuide: Data,
                           styleBoard: Data?,
                           apiKey: String,
                           session: URLSession) async throws -> GeneratedSleepFrame {
    var references = [
        PetProviderReference(filename: "locked-identity.png", data: identity, role: .identity),
        PetProviderReference(filename: "pose-\(String(format: "%02d", index + 1)).png",
                             data: poseGuide, role: .expression),
    ]
    if let styleBoard {
        references.append(PetProviderReference(
            filename: "mimo-style-board.png", data: styleBoard, role: .style))
    }
    let requestID = "mimo-\(actionKey)-single-\(String(format: "%02d", index + 1))-\(UUID().uuidString.lowercased())"
    let provider = PetOpenAIProvider(maximumBodyBytes: 32 * 1024 * 1024)
    let spec = PetImageRequestSpec(
        references: references,
        prompt: prompt,
        size: .square1024,
        quality: .low,
        delivery: .blocking,
        apiKey: apiKey,
        timeout: 240,
        boundary: "mimo-\(actionKey)-frame-\(UUID().uuidString.lowercased())")
    var request = try provider.buildRequest(spec)
    request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key")
    let started = Date()
    var responseData = Data()
    var http: HTTPURLResponse?
    for attempt in 1...8 {
        let (data, response) = try await session.data(for: request)
        responseData = data
        http = response as? HTTPURLResponse
        guard let currentHTTP = http else {
            throw SleepSingleFrameError.invalidResponse(
                "Frame \(index + 1) returned no HTTP response.")
        }
        if currentHTTP.statusCode == 429, attempt < 8 {
            let retryAfter = Int(currentHTTP.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 15
            log("rate-limit frame \(String(format: "%02d", index + 1)); retry in \(retryAfter)s")
            try await Task.sleep(for: .seconds(retryAfter))
            continue
        }
        break
    }
    guard let http, 200..<300 ~= http.statusCode else {
        throw SleepSingleFrameError.invalidResponse(
            providerError(responseData, status: http?.statusCode ?? 0))
    }
    guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          let rows = object["data"] as? [[String: Any]],
          let encoded = rows.first?["b64_json"] as? String,
          let pngData = Data(base64Encoded: encoded), !pngData.isEmpty,
          let dimensions = CharacterSheetProcessor.pngPixelDimensions(pngData),
          dimensions.width == 1024, dimensions.height == 1024 else {
        throw SleepSingleFrameError.invalidResponse(
            "Frame \(index + 1) returned an unreadable or wrongly sized image.")
    }
    let usage = object["usage"] as? [String: Any] ?? [:]
    log("complete  frame \(String(format: "%02d", index + 1))  "
        + "\(Int(Date().timeIntervalSince(started)))s  request \(requestID)")
    return GeneratedSleepFrame(
        index: index, pngData: pngData, usage: usage, requestID: requestID)
}

private func tiledGrid(_ frames: [GeneratedSleepFrame]) throws -> Data {
    let decoded = try frames.sorted(by: { $0.index < $1.index }).map {
        try CharacterSheetProcessor.decodePNG($0.pngData)
    }
    guard decoded.count == 16, decoded.allSatisfy({ $0.width == 1024 && $0.height == 1024 }) else {
        throw SleepSingleFrameError.incompleteFrames(
            Array(Set(0..<16).subtracting(frames.map(\.index))).sorted())
    }
    var grid = CharacterSheetRGBAImage(width: 4096, height: 4096)
    for (index, frame) in decoded.enumerated() {
        let originX = (index % 4) * 1024
        let originY = (index / 4) * 1024
        for y in 0..<1024 {
            let sourceStart = y * 1024 * 4
            let destinationStart = ((originY + y) * 4096 + originX) * 4
            grid.pixels.replaceSubrange(
                destinationStart..<(destinationStart + 1024 * 4),
                with: frame.pixels[sourceStart..<(sourceStart + 1024 * 4)])
        }
    }
    return try CharacterSheetProcessor.encodePNG(grid)
}

@main
struct SleepSingleFrameLiveRun {
    static func main() async {
        do { try await run() } catch {
            log("FAILED    \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            exit(EXIT_FAILURE)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4,
           arguments[1] == "--preflight" || arguments[1] == "--preflight-walk" {
            let identity = try input(arguments[2])
            let poseStrip = try input(arguments[3])
            let guides = arguments[1] == "--preflight-walk"
                ? try walkPoseGuides(from: poseStrip)
                : try poseGuides(from: poseStrip)
            guard let dimensions = CharacterSheetProcessor.pngPixelDimensions(identity),
                  dimensions.width == 512, dimensions.height == 512,
                  guides.count == 16 else {
                throw SleepSingleFrameError.invalidPoseStrip
            }
            log("preflight  identity 512x512; pose guides 16; credential \(MimoSecret.openAI.source.rawValue)")
            return
        }
        guard arguments.count == 6,
              arguments[1] == "--confirm-paid"
                || arguments[1] == "--confirm-paid-walk" else {
            throw SleepSingleFrameError.usage
        }

        let actionKey = arguments[1] == "--confirm-paid-walk" ? "walk" : "sleep"
        let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let identity = try input(arguments[3])
        let poseStrip = try input(arguments[4])
        let styleMaster = try input(arguments[5])
        guard let dimensions = CharacterSheetProcessor.pngPixelDimensions(identity),
              dimensions.width == 512, dimensions.height == 512 else {
            throw SleepSingleFrameError.missingInput(arguments[3])
        }
        let guides = actionKey == "walk"
            ? try walkPoseGuides(from: poseStrip)
            : try poseGuides(from: poseStrip)
        let styleBoard = MimoStyleReference.requestData(masterData: styleMaster)
        guard let apiKey = MimoSecret.openAI.read() else {
            throw SleepSingleFrameError.missingAPIKey
        }

        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let guideDirectory = outputDirectory.appendingPathComponent("pose-guides", isDirectory: true)
        let rawDirectory = outputDirectory.appendingPathComponent("raw-frames", isDirectory: true)
        let normalizedDirectory = outputDirectory.appendingPathComponent(
            "normalized-frames", isDirectory: true)
        for directory in [guideDirectory, rawDirectory, normalizedDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        for (index, guide) in guides.enumerated() {
            try write(guide, named: String(format: "pose-%02d.png", index + 1),
                      to: guideDirectory)
        }
        try write(identity, named: "reference-identity.png", to: outputDirectory)
        if let styleBoard {
            try write(styleBoard, named: "reference-style-board.png", to: outputDirectory)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 240
        configuration.timeoutIntervalForResource = 360
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        log("preflight  16 paid calls; gpt-image-2; low; 1024x1024; sequential resumable")
        log("credential \(MimoSecret.openAI.source.rawValue) (value never printed)")
        var generated: [GeneratedSleepFrame] = []
        for index in 0..<16 {
            let frameName = String(format: "frame-%02d.png", index + 1)
            let usageName = String(format: "frame-%02d-usage.json", index + 1)
            let frameURL = rawDirectory.appendingPathComponent(frameName)
            let usageURL = rawDirectory.appendingPathComponent(usageName)
            if let pngData = try? Data(contentsOf: frameURL), !pngData.isEmpty,
               let usageData = try? Data(contentsOf: usageURL),
               let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
               let dimensions = CharacterSheetProcessor.pngPixelDimensions(pngData),
               dimensions.width == 1024, dimensions.height == 1024 {
                log("resume     frame \(String(format: "%02d", index + 1)) already complete")
                generated.append(GeneratedSleepFrame(
                    index: index, pngData: pngData, usage: usage,
                    requestID: "resume-existing-\(index + 1)"))
                continue
            }
            log("generate   frame \(String(format: "%02d", index + 1))")
            let frame = try await generateFrame(
                index: index, actionKey: actionKey,
                prompt: actionKey == "walk"
                    ? walkFramePrompt(index: index, hasStyleBoard: styleBoard != nil)
                    : framePrompt(index: index, hasStyleBoard: styleBoard != nil),
                identity: identity, poseGuide: guides[index],
                styleBoard: styleBoard, apiKey: apiKey, session: session)
            generated.append(frame)
            try write(frame.pngData, named: frameName, to: rawDirectory)
            let usageData = try JSONSerialization.data(
                withJSONObject: frame.usage, options: [.prettyPrinted, .sortedKeys])
            try write(usageData, named: usageName, to: rawDirectory)
        }
        let missing = Array(Set(0..<16).subtracting(generated.map(\.index))).sorted()
        guard missing.isEmpty else { throw SleepSingleFrameError.incompleteFrames(missing) }

        let gridData = try tiledGrid(generated)
        try write(gridData, named: "\(actionKey)-single-frame-raw-grid.png",
                  to: outputDirectory)
        let processed = try ActionSheetProcessor.process(
            pngData: gridData, layout: .fourByFour)
        try write(processed.pngData, named: "\(actionKey)-single-frame-strip.png",
                  to: outputDirectory)

        let strip = try CharacterSheetProcessor.decodePNG(processed.pngData)
        for index in 0..<16 {
            let frame = ActionSheetProcessor.crop(
                strip, x: index * processed.cellSize, y: 0,
                width: processed.cellSize, height: processed.cellSize)
            try write(try CharacterSheetProcessor.encodePNG(frame),
                      named: String(format: "frame-%02d.png", index + 1),
                      to: normalizedDirectory)
        }
        let runObject: [String: Any] = [
            "schemaVersion": 1,
            "model": PetOpenAIProvider.defaultModel,
            "quality": PetGenerationQuality.low.rawValue,
            "action": actionKey,
            "frameCount": 16,
            "requestIDs": Dictionary(
                uniqueKeysWithValues: generated.map { (String($0.index + 1), $0.requestID) }),
        ]
        try write(
            try JSONSerialization.data(
                withJSONObject: runObject, options: [.prettyPrinted, .sortedKeys]),
            named: "run.json", to: outputDirectory)
        log("RESULT    generated and normalized sixteen independent \(actionKey) frames; not installed")
    }
}
