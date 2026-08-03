// sources: starter_action.swift
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func section(_ text: String, after start: String, before end: String) -> String {
    guard let lower = text.range(of: start)?.lowerBound,
          let upper = text.range(of: end, range: lower..<text.endIndex)?.lowerBound else {
        return ""
    }
    return String(text[lower..<upper])
}

@main
struct ClassifierEraseTests {
    static func main() throws {
        let main = try String(contentsOfFile: "mac/main.swift", encoding: .utf8)
        let product = try String(contentsOfFile: "mac/product.swift", encoding: .utf8)
        let classifier = section(main, after: "final class SmartClassifier",
                                 before: "func idleSeconds()")
        let deleteAll = section(product, after: "case \"all\":",
                                before: "default: break")

        expect(classifier.contains("private var epoch: UInt64 = 0")
               && classifier.contains("private var inFlight: [String: UInt64]"),
               "classifier tracks every in-flight verdict by erase epoch")
        expect(classifier.contains("func eraseAllDerivedData()")
               && classifier.contains("epoch &+= 1")
               && classifier.contains("cache.removeAll")
               && classifier.contains("inFlight.removeAll")
               && classifier.contains("removeObject(forKey: \"aiVerdicts\")"),
               "classifier erase clears memory and persisted automatic verdicts")
        expect(classifier.contains("let requestEpoch = epoch")
               && classifier.contains("inFlight[key] = requestEpoch")
               && classifier.contains("self.inFlight[key] == requestEpoch")
               && classifier.contains("guard self.epoch == requestEpoch else { return }"),
               "a completion from before erase cannot mutate the new epoch")

        expect(deleteAll.contains("SmartClassifier.shared.eraseAllDerivedData()")
               && deleteAll.contains("removeObject(forKey: \"seenItems\")")
               && deleteAll.contains("rulesKeys.removeAll()"),
               "Delete Everything clears classifier output and automatically seen items")
        expect(!deleteAll.contains("removeObject(forKey: \"ruleOverrides\")")
               && !deleteAll.contains("ruleOverrides.removeAll"),
               "Delete Everything preserves manual classification overrides")

        print("classifier erase tests passed")
    }
}
