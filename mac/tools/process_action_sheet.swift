import Foundation

private struct ActionSheetFrameReport: Codable {
    let index: Int
    let sourceBounds: CharacterSheetPixelBounds
    let anchorX: Int
    let anchorY: Int
}

private struct ActionSheetCLIReport: Codable {
    let source: String
    let output: String
    let rows: Int
    let columns: Int
    let frameCount: Int
    let cellSize: Int
    let frames: [ActionSheetFrameReport]
}

private struct ActionSheetInterleaveReport: Codable {
    let keyframes: String
    let inbetweens: String
    let output: String
    let frameCount: Int
    let cellSize: Int
}

@main
private enum ProcessActionSheetCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "interleave" {
            try interleave(arguments)
            return
        }
        guard (4...5).contains(arguments.count),
              let rows = Int(arguments[2]), rows > 0,
              let columns = Int(arguments[3]), columns > 0 else {
            FileHandle.standardError.write(Data(
                """
                usage: process_action_sheet INPUT.png OUTPUT.png ROWS COLUMNS [REPORT.json]
                       process_action_sheet interleave KEYFRAMES.png INBETWEENS.png OUTPUT.png [REPORT.json]

                """
                    .utf8))
            throw Exit.failure
        }

        let sourceURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let sourceData = try Data(contentsOf: sourceURL)
        let result = try ActionSheetProcessor.process(
            pngData: sourceData,
            layout: ActionSheetLayout(rows: rows, columns: columns))
        try result.pngData.write(to: outputURL, options: [.atomic])

        let report = ActionSheetCLIReport(
            source: sourceURL.path,
            output: outputURL.path,
            rows: rows,
            columns: columns,
            frameCount: result.frames.count,
            cellSize: result.cellSize,
            frames: result.frames.map {
                ActionSheetFrameReport(
                    index: $0.index,
                    sourceBounds: $0.bounds,
                    anchorX: $0.anchorX,
                    anchorY: $0.anchorY)
            })
        let encoded = try JSONEncoder.pretty.encode(report)
        if arguments.count == 5 {
            try encoded.write(
                to: URL(fileURLWithPath: arguments[4]).standardizedFileURL,
                options: [.atomic])
        } else {
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func interleave(_ arguments: [String]) throws {
        guard (4...5).contains(arguments.count) else {
            throw Exit.failure
        }
        let keyframesURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let inbetweensURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let output = try ActionSheetProcessor.interleaveStrips(
            keyframesPNG: Data(contentsOf: keyframesURL),
            inbetweensPNG: Data(contentsOf: inbetweensURL))
        try output.write(to: outputURL, options: [.atomic])

        guard let image = try? CharacterSheetProcessor.decodePNG(output),
              image.height > 0, image.width % image.height == 0 else {
            throw Exit.failure
        }
        let report = ActionSheetInterleaveReport(
            keyframes: keyframesURL.path,
            inbetweens: inbetweensURL.path,
            output: outputURL.path,
            frameCount: image.width / image.height,
            cellSize: image.height)
        let encoded = try JSONEncoder.pretty.encode(report)
        if arguments.count == 5 {
            try encoded.write(
                to: URL(fileURLWithPath: arguments[4]).standardizedFileURL,
                options: [.atomic])
        } else {
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private enum Exit: Error {
        case failure
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
