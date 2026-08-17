// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct FaceModelPackagingTests {
    static func main() throws {
        let build = try String(contentsOfFile: "mac/build.sh", encoding: .utf8)
        let helperURL = URL(fileURLWithPath: "mac/face_models.sh")
        expect(FileManager.default.fileExists(atPath: helperURL.path),
               "build needs a reusable compiled-model validity check")
        let helper = (try? String(contentsOf: helperURL, encoding: .utf8)) ?? ""
        expect(build.contains("source ./face_models.sh")
               && build.contains("mimo_compiled_face_model_is_valid")
               && helper.contains("coremldata.bin")
               && helper.contains(".local/face-models"),
               "build must reject empty mlmodelc shells and prefer persistent local storage")
        expect(!build.contains("MIMO_FACE_MODEL_DIR:-/private/tmp/mimo-face-compiled"),
               "volatile /private/tmp must not remain the default model source")
        print("face model packaging regression test passed")
    }
}
