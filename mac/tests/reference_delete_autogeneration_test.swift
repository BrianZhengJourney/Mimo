// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func section(_ source: String, from start: String, to end: String) -> String {
    guard let lower = source.range(of: start)?.lowerBound,
          let upper = source.range(of: end, range: lower..<source.endIndex)?.lowerBound else {
        return ""
    }
    return String(source[lower..<upper])
}

@main
struct ReferenceDeleteAutogenerationTests {
    static func main() throws {
        let settings = try String(
            contentsOfFile: "mac/settings.html", encoding: .utf8)
        let changed = section(
            settings, from: "function referenceSetChanged(",
            to: "function setPrimaryReference(")

        guard let suppression = changed.range(of: "if(!autoGenerate){"),
              let cancellation = changed.range(
                of: "clearTimeout(candidateAutoGenerateTimer)"),
              let handled = changed.range(
                of: "candidateAutoGenerateSignature=candidateReferenceSignature()"),
              let invalidation = changed.range(of: "invalidatePetDraft();") else {
            expect(false,
                   "manual reference removal needs an explicit pre-render auto-generation fence")
            return
        }

        expect(suppression.lowerBound < invalidation.lowerBound
               && cancellation.lowerBound < invalidation.lowerBound
               && handled.lowerBound < invalidation.lowerBound,
               "deletion must cancel and mark the reduced reference set before render can schedule generation")
        print("reference deletion auto-generation regression test passed")
    }
}
