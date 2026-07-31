import Foundation

// A small expression language for behavior packs.
//
// Shimeji embeds real JavaScript in XML attributes and evaluates it against
// live engine objects, so `mascot.environment.floor.isOn(mascot.anchor)` is a
// reflective walk into internals. That welds the config format to the engine's
// class shape, runs an eval per attribute per companion per frame, and is an
// untrusted-code surface. See docs/companion/01-shimeji-research.md §1.9.
//
// This is deliberately not that. No method calls, no assignment, no loops, no
// function definitions — just arithmetic, comparison, logic, a fixed set of
// pure builtins, and named variables drawn from an explicit schema. A pack
// cannot reach anything the schema does not name, and misspelling a variable is
// a load error rather than a silently false condition.
//
// The `$` / `#` distinction is preserved from Shimeji and matters: `${...}` is
// evaluated once when an action starts and cached, `#{...}` is re-evaluated
// every frame. Without it, `duration: "${2 + random() * 3}"` would re-roll
// continuously instead of committing to one value. libshijima dropped this
// distinction; we do not.

enum CompanionValue: Equatable {
    case number(Double)
    case boolean(Bool)
    case text(String)

    var asDouble: Double? {
        switch self {
        case .number(let value): return value
        case .boolean(let value): return value ? 1 : 0
        case .text: return nil
        }
    }

    var asBool: Bool {
        switch self {
        case .number(let value): return value != 0
        case .boolean(let value): return value
        case .text(let value): return !value.isEmpty
        }
    }
}

enum CompanionExpressionError: Error, CustomStringConvertible {
    case malformed(String)
    case unknownVariable(String)
    case unknownFunction(String)
    case wrongArgumentCount(String, expected: Int, got: Int)

    var description: String {
        switch self {
        case .malformed(let detail): return "malformed expression: \(detail)"
        case .unknownVariable(let name): return "unknown variable '\(name)'"
        case .unknownFunction(let name): return "unknown function '\(name)'"
        case .wrongArgumentCount(let name, let expected, let got):
            return "\(name) takes \(expected) argument(s), got \(got)"
        }
    }
}

/// How often a compiled expression is evaluated.
enum CompanionEvaluationMode: Equatable {
    /// `${...}` — evaluated once when the action starts, then cached.
    case once
    /// `#{...}` — evaluated every frame.
    case everyFrame
}

// MARK: - Variable schema

/// The names a pack may reference. Explicit and versioned so a pack is not
/// coupled to the engine's internal shape, and so typos fail at load.
struct CompanionVariableSchema {
    let names: Set<String>

    static let current = CompanionVariableSchema(names: [
        // world
        "world.cursor.x", "world.cursor.y", "world.cursor.dx", "world.cursor.dy",
        "world.display.width", "world.display.height",
        "world.display.workArea.left", "world.display.workArea.right",
        "world.display.workArea.top", "world.display.workArea.bottom",
        "world.companionCount",
        // self
        "self.anchor.x", "self.anchor.y",
        "self.lookRight", "self.state", "self.footX", "self.surface",
        "self.heldSeconds", "self.groundedSeconds", "self.airborneSeconds",
        "self.attachedSeconds",
        // Mimo's semantic layer — the thing Shimeji has no equivalent of.
        // Behaviour can be gated on what the user is actually doing.
        "mimo.mood", "mimo.focusMinutes", "mimo.streakMinutes",
        "mimo.isIdle", "mimo.paused",
    ])

    func contains(_ name: String) -> Bool { names.contains(name) }
}

/// Supplies variable values at evaluation time.
protocol CompanionVariableSource {
    func value(for name: String) -> CompanionValue?
}

struct CompanionVariableBag: CompanionVariableSource {
    var values: [String: CompanionValue] = [:]
    func value(for name: String) -> CompanionValue? { values[name] }
}

// MARK: - AST

indirect enum CompanionNode {
    case literal(CompanionValue)
    case variable(String)
    case unary(String, CompanionNode)
    case binary(String, CompanionNode, CompanionNode)
    case ternary(CompanionNode, CompanionNode, CompanionNode)
    case call(String, [CompanionNode])
}

// MARK: - Compiled expression

struct CompanionExpression {
    let source: String
    let mode: CompanionEvaluationMode
    let root: CompanionNode

    /// Parses `${...}`, `#{...}`, or a bare literal.
    ///
    /// A bare number or boolean is common enough in packs (`"frequency": 100`)
    /// that requiring a wrapper would be noise.
    static func compile(_ raw: String,
                        schema: CompanionVariableSchema = .current) throws -> CompanionExpression {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var mode = CompanionEvaluationMode.once
        var body = trimmed

        if trimmed.hasPrefix("${") || trimmed.hasPrefix("#{") {
            guard trimmed.hasSuffix("}") else {
                throw CompanionExpressionError.malformed("unterminated '\(trimmed)'")
            }
            mode = trimmed.hasPrefix("#{") ? .everyFrame : .once
            body = String(trimmed.dropFirst(2).dropLast())
        }

        var parser = CompanionParser(source: body)
        let root = try parser.parseExpression()
        try parser.expectEnd()
        try validate(root, schema: schema)
        return CompanionExpression(source: trimmed, mode: mode, root: root)
    }

    /// Rejects unknown names at load rather than yielding false at runtime.
    /// Shimeji surfaces this class of authoring error as a companion that
    /// mysteriously rains from the sky.
    private static func validate(_ node: CompanionNode,
                                 schema: CompanionVariableSchema) throws {
        switch node {
        case .literal:
            return
        case .variable(let name):
            guard schema.contains(name) else {
                throw CompanionExpressionError.unknownVariable(name)
            }
        case .unary(_, let operand):
            try validate(operand, schema: schema)
        case .binary(_, let lhs, let rhs):
            try validate(lhs, schema: schema)
            try validate(rhs, schema: schema)
        case .ternary(let condition, let whenTrue, let whenFalse):
            try validate(condition, schema: schema)
            try validate(whenTrue, schema: schema)
            try validate(whenFalse, schema: schema)
        case .call(let name, let arguments):
            guard let arity = CompanionBuiltin.arity[name] else {
                throw CompanionExpressionError.unknownFunction(name)
            }
            guard arity < 0 || arity == arguments.count else {
                throw CompanionExpressionError.wrongArgumentCount(
                    name, expected: arity, got: arguments.count)
            }
            for argument in arguments { try validate(argument, schema: schema) }
        }
    }

    func evaluate(_ source: CompanionVariableSource,
                  random: () -> Double = { Double.random(in: 0..<1) }) -> CompanionValue {
        CompanionExpression.evaluate(root, source, random)
    }

    func evaluateBool(_ source: CompanionVariableSource,
                      random: () -> Double = { Double.random(in: 0..<1) }) -> Bool {
        evaluate(source, random: random).asBool
    }

    func evaluateDouble(_ source: CompanionVariableSource,
                        random: () -> Double = { Double.random(in: 0..<1) }) -> Double? {
        evaluate(source, random: random).asDouble
    }

    private static func evaluate(_ node: CompanionNode,
                                 _ source: CompanionVariableSource,
                                 _ random: () -> Double) -> CompanionValue {
        switch node {
        case .literal(let value):
            return value

        case .variable(let name):
            // A schema-valid name with no value this frame reads as 0 rather
            // than trapping: the source is a live snapshot and a field can be
            // legitimately absent (no cursor delta before the first move).
            return source.value(for: name) ?? .number(0)

        case .unary(let op, let operand):
            let value = evaluate(operand, source, random)
            switch op {
            case "-": return .number(-(value.asDouble ?? 0))
            case "!": return .boolean(!value.asBool)
            default: return .number(0)
            }

        case .binary(let op, let lhsNode, let rhsNode):
            // Short-circuit before evaluating the right side.
            if op == "&&" {
                let lhs = evaluate(lhsNode, source, random)
                return .boolean(lhs.asBool ? evaluate(rhsNode, source, random).asBool : false)
            }
            if op == "||" {
                let lhs = evaluate(lhsNode, source, random)
                return .boolean(lhs.asBool ? true : evaluate(rhsNode, source, random).asBool)
            }

            let lhs = evaluate(lhsNode, source, random)
            let rhs = evaluate(rhsNode, source, random)

            if op == "==" { return .boolean(equal(lhs, rhs)) }
            if op == "!=" { return .boolean(!equal(lhs, rhs)) }

            let a = lhs.asDouble ?? 0, b = rhs.asDouble ?? 0
            switch op {
            case "+": return .number(a + b)
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            case "/": return .number(b == 0 ? 0 : a / b)
            case "%": return .number(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))
            case "<": return .boolean(a < b)
            case "<=": return .boolean(a <= b)
            case ">": return .boolean(a > b)
            case ">=": return .boolean(a >= b)
            default: return .number(0)
            }

        case .ternary(let condition, let whenTrue, let whenFalse):
            return evaluate(condition, source, random).asBool
                ? evaluate(whenTrue, source, random)
                : evaluate(whenFalse, source, random)

        case .call(let name, let arguments):
            let values = arguments.map { evaluate($0, source, random) }
            return CompanionBuiltin.apply(name, values, random)
        }
    }

    /// Strings compare as strings; everything else numerically. Lets a pack
    /// write `mimo.mood == 'deepWork'` and compare another typed value with one operator.
    private static func equal(_ lhs: CompanionValue, _ rhs: CompanionValue) -> Bool {
        if case .text(let a) = lhs, case .text(let b) = rhs { return a == b }
        if case .text = lhs { return false }
        if case .text = rhs { return false }
        return (lhs.asDouble ?? 0) == (rhs.asDouble ?? 0)
    }
}

// MARK: - Builtins

enum CompanionBuiltin {
    /// Negative arity means variadic.
    static let arity: [String: Int] = [
        "random": 0, "abs": 1, "floor": 1, "ceil": 1, "round": 1,
        "min": -1, "max": -1, "clamp": 3,
    ]

    static func apply(_ name: String, _ values: [CompanionValue],
                      _ random: () -> Double) -> CompanionValue {
        let numbers = values.map { $0.asDouble ?? 0 }
        switch name {
        case "random": return .number(random())
        case "abs": return .number(abs(numbers.first ?? 0))
        case "floor": return .number((numbers.first ?? 0).rounded(.down))
        case "ceil": return .number((numbers.first ?? 0).rounded(.up))
        case "round": return .number((numbers.first ?? 0).rounded())
        case "min": return .number(numbers.min() ?? 0)
        case "max": return .number(numbers.max() ?? 0)
        case "clamp":
            guard numbers.count == 3 else { return .number(numbers.first ?? 0) }
            return .number(Swift.min(Swift.max(numbers[0], numbers[1]), numbers[2]))
        default: return .number(0)
        }
    }
}

// MARK: - Parser

/// Precedence-climbing recursive descent. Small enough to audit in one sitting,
/// which is the point — this replaces an embedded JavaScript engine.
private struct CompanionParser {
    private let characters: [Character]
    private var index = 0

    init(source: String) {
        characters = Array(source)
    }

    mutating func parseExpression() throws -> CompanionNode {
        try parseTernary()
    }

    mutating func expectEnd() throws {
        skipWhitespace()
        guard index >= characters.count else {
            throw CompanionExpressionError.malformed(
                "unexpected '\(String(characters[index...]))'")
        }
    }

    // MARK: precedence levels

    private mutating func parseTernary() throws -> CompanionNode {
        let condition = try parseBinary(minimumPrecedence: 0)
        skipWhitespace()
        guard match("?") else { return condition }
        let whenTrue = try parseTernary()
        skipWhitespace()
        guard match(":") else {
            throw CompanionExpressionError.malformed("ternary missing ':'")
        }
        let whenFalse = try parseTernary()
        return .ternary(condition, whenTrue, whenFalse)
    }

    private static let precedence: [String: Int] = [
        "||": 1, "&&": 2,
        "==": 3, "!=": 3,
        "<": 4, "<=": 4, ">": 4, ">=": 4,
        "+": 5, "-": 5,
        "*": 6, "/": 6, "%": 6,
    ]

    private mutating func parseBinary(minimumPrecedence: Int) throws -> CompanionNode {
        var lhs = try parseUnary()
        while true {
            skipWhitespace()
            guard let op = peekOperator(),
                  let precedence = Self.precedence[op],
                  precedence >= minimumPrecedence else { return lhs }
            index += op.count
            let rhs = try parseBinary(minimumPrecedence: precedence + 1)
            lhs = .binary(op, lhs, rhs)
        }
    }

    private mutating func parseUnary() throws -> CompanionNode {
        skipWhitespace()
        if match("!") { return .unary("!", try parseUnary()) }
        if peek() == "-" {
            index += 1
            return .unary("-", try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> CompanionNode {
        skipWhitespace()
        guard let character = peek() else {
            throw CompanionExpressionError.malformed("unexpected end of expression")
        }

        if character == "(" {
            index += 1
            let inner = try parseExpression()
            skipWhitespace()
            guard match(")") else {
                throw CompanionExpressionError.malformed("missing ')'")
            }
            return inner
        }

        if character == "'" || character == "\"" {
            return .literal(.text(try parseString(quote: character)))
        }

        if character.isNumber || character == "." {
            return .literal(.number(try parseNumber()))
        }

        if character.isLetter || character == "_" {
            let name = parseIdentifier()
            skipWhitespace()
            if peek() == "(" {
                index += 1
                let arguments = try parseArguments()
                return .call(name, arguments)
            }
            if name == "true" { return .literal(.boolean(true)) }
            if name == "false" { return .literal(.boolean(false)) }
            return .variable(name)
        }

        throw CompanionExpressionError.malformed("unexpected '\(character)'")
    }

    private mutating func parseArguments() throws -> [CompanionNode] {
        var arguments: [CompanionNode] = []
        skipWhitespace()
        if match(")") { return arguments }
        while true {
            arguments.append(try parseExpression())
            skipWhitespace()
            if match(")") { return arguments }
            guard match(",") else {
                throw CompanionExpressionError.malformed("expected ',' or ')' in arguments")
            }
        }
    }

    // MARK: lexing

    private mutating func parseNumber() throws -> Double {
        let start = index
        var sawDot = false
        while let character = peek() {
            if character.isNumber { index += 1; continue }
            if character == ".", !sawDot { sawDot = true; index += 1; continue }
            break
        }
        let text = String(characters[start..<index])
        guard let value = Double(text) else {
            throw CompanionExpressionError.malformed("bad number '\(text)'")
        }
        return value
    }

    private mutating func parseString(quote: Character) throws -> String {
        index += 1
        var result = ""
        while let character = peek(), character != quote {
            result.append(character)
            index += 1
        }
        guard match(quote) else {
            throw CompanionExpressionError.malformed("unterminated string")
        }
        return result
    }

    /// Dotted paths are one identifier: `world.display.workArea.left`.
    private mutating func parseIdentifier() -> String {
        let start = index
        while let character = peek(),
              character.isLetter || character.isNumber || character == "_" || character == "." {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func peekOperator() -> String? {
        guard index < characters.count else { return nil }
        if index + 1 < characters.count {
            let pair = String(characters[index...index + 1])
            if Self.precedence[pair] != nil { return pair }
        }
        let single = String(characters[index])
        // Bare '=' is almost certainly a typo for '==' rather than assignment,
        // which this language does not have.
        if single == "=" { return nil }
        return Self.precedence[single] != nil ? single : nil
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    private mutating func match(_ character: Character) -> Bool {
        guard peek() == character else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let character = peek(), character.isWhitespace { index += 1 }
    }
}
