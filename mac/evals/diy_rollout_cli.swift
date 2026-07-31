import Foundation

private enum RolloutCLIError: Error, CustomStringConvertible {
    case usage(String)
    case invalidJSON(String)

    var description: String {
        switch self {
        case .usage(let value), .invalidJSON(let value): return value
        }
    }
}

private func option(_ name: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        throw RolloutCLIError.usage("missing \(name)")
    }
    return arguments[index + 1]
}

private func decode<T: Decodable>(_ type: T.Type, path: String) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        throw RolloutCLIError.invalidJSON("invalid rollout evidence at \(path): \(error)")
    }
}

private func write(_ ledger: DIYRolloutLedger, path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(ledger)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

private func now() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func printStatus(_ ledger: DIYRolloutLedger) {
    print("\(ledger.status.rawValue) · \(ledger.stagePercent)% · \(ledger.candidateCommit)")
    if let last = ledger.events.last, !last.failedGates.isEmpty {
        print("failed: \(last.failedGates.joined(separator: ", "))")
    }
}

@main
private struct DIYRolloutCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw RolloutCLIError.usage(
                "usage: start|observe|rollback|status|bucket [options]")
        }
        switch command {
        case "start":
            let baseline = try decode(
                DIYRolloutEvidence.self, path: option("--baseline", in: arguments))
            let candidate = try decode(
                DIYRolloutEvidence.self, path: option("--candidate", in: arguments))
            let statePath = try option("--state", in: arguments)
            let ledger = DIYRolloutController.start(
                baseline: baseline, candidate: candidate, now: now())
            try write(ledger, path: statePath)
            printStatus(ledger)
            if ledger.status == .blocked { exit(2) }
        case "observe":
            let statePath = try option("--state", in: arguments)
            let ledger = try decode(DIYRolloutLedger.self, path: statePath)
            let evidence = try decode(
                DIYRolloutEvidence.self, path: option("--metrics", in: arguments))
            let next = DIYRolloutController.observe(evidence, ledger: ledger, now: now())
            try write(next, path: statePath)
            printStatus(next)
            if next.status == .rolledBack { exit(3) }
        case "rollback":
            let statePath = try option("--state", in: arguments)
            let ledger = try decode(DIYRolloutLedger.self, path: statePath)
            let next = DIYRolloutController.rollback(
                ledger: ledger, reason: try option("--reason", in: arguments), now: now())
            try write(next, path: statePath)
            printStatus(next)
        case "status":
            printStatus(try decode(
                DIYRolloutLedger.self, path: option("--state", in: arguments)))
        case "bucket":
            let ledger = try decode(
                DIYRolloutLedger.self, path: option("--state", in: arguments))
            let identifier = try option("--id", in: arguments)
            print(ledger.includes(identifier: identifier) ? "included" : "baseline")
        default:
            throw RolloutCLIError.usage("unknown rollout command: \(command)")
        }
    }
}
