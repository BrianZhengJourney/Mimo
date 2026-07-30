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

        let humanAsset = URL(fileURLWithPath:
            "mac/assets/style-reference/mimo-human-style-reference-board.png")
        let humanData = try Data(contentsOf: humanAsset)
        expect(MimoStyleReference.isValid(humanData, profile: .humanV2),
               "the dedicated human style board contract should validate")
        expect(!MimoStyleReference.isValid(humanData, profile: .creatureV1),
               "human and creature boards must not be silently interchanged")
        let humanRequest = MimoStyleReference.requestData(
            masterData: humanData, profile: .humanV2)
        let humanImage = humanRequest.flatMap(NSBitmapImageRep.init(data:))
        expect(humanImage?.pixelsWide == MimoStyleReference.humanRequestWidth
               && humanImage?.pixelsHigh == MimoStyleReference.humanRequestHeight,
               "human requests should preserve the wide three-take aspect ratio")
        expect(MimoStyleReference.assetSHA256(profile: .humanV2)
               == "b0ed194b98d843b962aa5e301b9296daf254a1afbdc0030eaee52925a3c6316b",
               "the saved human board must remain the approved white-outfit source")

        let motionAsset = URL(fileURLWithPath:
            "mac/assets/motion-reference/biped-walk-cycle-16.png")
        let motionData = try Data(contentsOf: motionAsset)
        expect(MimoMotionReference.isValid(motionData),
               "the deterministic 16-key-pose biped timing guide should validate")
        let midpointAsset = URL(fileURLWithPath:
            "mac/assets/motion-reference/biped-walk-inbetweens-16.png")
        let midpointData = try Data(contentsOf: midpointAsset)
        expect(MimoMotionReference.isValid(midpointData),
               "the deterministic 16-midpoint biped timing guide should validate")
        print("style reference tests passed")
    }
}
