// sources: style_reference.swift
import Cocoa
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct StyleReferenceTests {
    static func main() throws {
        let asset = URL(fileURLWithPath: CommandLine.arguments.count > 1
                        ? CommandLine.arguments[1]
                        : "mac/assets/style-reference/mimo-style-reference-board.png")
        let data = try Data(contentsOf: asset)
        expect(MimoStyleReference.isValid(data), "the bundled style board contract should validate")
        let requestData = MimoStyleReference.requestData(masterData: data)
        let requestImage = requestData.flatMap(NSBitmapImageRep.init(data:))
        expect(requestImage?.pixelsWide == MimoStyleReference.requestWidth
               && requestImage?.pixelsHigh == MimoStyleReference.requestHeight,
               "provider requests should use the lower-token half-size style reference")

        var wrongDimensions = data
        wrongDimensions.replaceSubrange(16..<20, with: [0, 0, 4, 0])
        expect(!MimoStyleReference.isValid(wrongDimensions), "unexpected dimensions must be rejected")
        expect(!MimoStyleReference.isValid(Data("not a png".utf8)), "non-PNG data must be rejected")
        print("style reference tests passed")
    }
}
