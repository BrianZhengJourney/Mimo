// sources: companion_expression.swift
import Foundation

@main
struct CompanionExpressionTests {
    static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
    }

    static func expectClose(_ actual: Double, _ expected: Double, _ label: String) {
        precondition(abs(actual - expected) < 0.0001,
                     "\(label): expected \(expected), got \(actual)")
    }

    static func bag(_ pairs: [String: CompanionValue]) -> CompanionVariableBag {
        CompanionVariableBag(values: pairs)
    }

    static func number(_ source: String,
                       _ values: [String: CompanionValue] = [:],
                       random: @escaping () -> Double = { 0.5 }) -> Double {
        let expression = try! CompanionExpression.compile(source)
        return expression.evaluateDouble(bag(values), random: random) ?? .nan
    }

    static func truth(_ source: String,
                      _ values: [String: CompanionValue] = [:]) -> Bool {
        let expression = try! CompanionExpression.compile(source)
        return expression.evaluateBool(bag(values), random: { 0.5 })
    }

    // MARK: - Arithmetic and precedence

    static func testArithmetic() {
        expectClose(number("1 + 2 * 3"), 7, "multiplication binds tighter than addition")
        expectClose(number("(1 + 2) * 3"), 9, "parentheses override precedence")
        expectClose(number("10 - 4 - 3"), 3, "subtraction is left-associative")
        expectClose(number("7 % 3"), 1, "modulo")
        expectClose(number("-5 + 2"), -3, "unary minus")
        expectClose(number("2.5 * 4"), 10, "decimals")
    }

    /// Division by zero yields 0 rather than infinity. A pack author's typo
    /// should produce a still companion, not one flung to infinity.
    static func testDivisionByZeroIsContained() {
        expectClose(number("5 / 0"), 0, "division by zero is contained")
        expectClose(number("5 % 0"), 0, "modulo by zero is contained")
    }

    static func testComparisonAndLogic() {
        expect(truth("3 > 2"), "greater than")
        expect(truth("2 <= 2"), "less or equal")
        expect(truth("1 == 1 && 2 < 3"), "conjunction")
        expect(truth("false || true"), "disjunction")
        expect(!truth("!true"), "negation")
        expect(truth("3 != 4"), "inequality")
    }

    static func testTernary() {
        expectClose(number("true ? 1 : 2"), 1, "ternary true branch")
        expectClose(number("false ? 1 : 2"), 2, "ternary false branch")
        expectClose(number("3 > 4 ? 10 : 20"), 20, "ternary on a comparison")
    }

    // MARK: - Variables

    static func testVariables() {
        expectClose(number("self.anchor.x + 10", ["self.anchor.x": .number(5)]), 15,
                    "dotted variable path resolves as one name")
        expect(truth("mimo.mood == 'deepWork'", ["mimo.mood": .text("deepWork")]),
               "string comparison")
        expect(!truth("mimo.mood == 'deepWork'", ["mimo.mood": .text("idle")]),
               "string comparison rejects a different value")
        expect(truth("self.lookRight", ["self.lookRight": .boolean(true)]),
               "boolean variable is truthy on its own")
    }

    /// A schema-valid name that the live snapshot has no value for reads as 0.
    /// The source is a per-frame snapshot and fields can be legitimately absent.
    static func testMissingValueIsZeroNotACrash() {
        expectClose(number("world.cursor.dx + 1"), 1, "absent value reads as zero")
    }

    // MARK: - Load-time validation

    /// The whole point of a fixed schema: a typo fails at load, where it can
    /// name itself, instead of evaluating false forever at runtime. Shimeji
    /// surfaces this class of error as a mascot that mysteriously falls out of
    /// the sky.
    static func testUnknownVariableIsRejectedAtCompileTime() {
        do {
            _ = try CompanionExpression.compile("#{self.anchor.z > 0}")
            preconditionFailure("a misspelled variable must not compile")
        } catch let error as CompanionExpressionError {
            guard case .unknownVariable(let name) = error else {
                preconditionFailure("expected unknownVariable, got \(error)")
            }
            expect(name == "self.anchor.z", "the error names the offending variable")
        } catch {
            preconditionFailure("unexpected error \(error)")
        }
    }

    static func testUnknownFunctionIsRejected() {
        do {
            _ = try CompanionExpression.compile("${eval(1)}")
            preconditionFailure("an unknown function must not compile")
        } catch let error as CompanionExpressionError {
            guard case .unknownFunction = error else {
                preconditionFailure("expected unknownFunction, got \(error)")
            }
        } catch {
            preconditionFailure("unexpected error \(error)")
        }
    }

    static func testArgumentCountIsChecked() {
        do {
            _ = try CompanionExpression.compile("${abs(1, 2)}")
            preconditionFailure("wrong arity must not compile")
        } catch let error as CompanionExpressionError {
            guard case .wrongArgumentCount = error else {
                preconditionFailure("expected wrongArgumentCount, got \(error)")
            }
        } catch {
            preconditionFailure("unexpected error \(error)")
        }
    }

    static func testMalformedExpressionsAreRejected() {
        for source in ["${1 +}", "${(1 + 2}", "${'unterminated}", "${1 ? 2}", "${}"] {
            var threw = false
            do { _ = try CompanionExpression.compile(source) } catch { threw = true }
            expect(threw, "'\(source)' must fail to compile")
        }
    }

    /// No assignment, no method calls, no property writes. The language cannot
    /// express them, which is the security property that lets a pack be data.
    static func testLanguageHasNoEscapeHatches() {
        for source in ["${self.anchor.x = 5}",
                       "${world.cursor.x.toString()}",
                       "${[1,2,3]}"] {
            var threw = false
            do { _ = try CompanionExpression.compile(source) } catch { threw = true }
            expect(threw, "'\(source)' must not be expressible")
        }
    }

    // MARK: - Evaluation mode

    /// The distinction libshijima dropped. `${...}` commits to one value when
    /// the action starts; `#{...}` tracks. Without it a randomised duration
    /// would re-roll every frame and never elapse.
    static func testEvaluationModeIsCarried() {
        let once = try! CompanionExpression.compile("${1 + 1}")
        expect(once.mode == .once, "$ means evaluate once")

        let live = try! CompanionExpression.compile("#{1 + 1}")
        expect(live.mode == .everyFrame, "# means evaluate every frame")

        let bare = try! CompanionExpression.compile("42")
        expect(bare.mode == .once, "a bare literal needs no wrapper and is constant")
        expectClose(bare.evaluateDouble(bag([:])) ?? .nan, 42, "bare literal value")
    }

    // MARK: - Builtins

    static func testBuiltins() {
        expectClose(number("abs(-3)"), 3, "abs")
        expectClose(number("floor(2.9)"), 2, "floor")
        expectClose(number("ceil(2.1)"), 3, "ceil")
        expectClose(number("round(2.5)"), 3, "round")
        expectClose(number("min(4, 2, 9)"), 2, "min is variadic")
        expectClose(number("max(4, 2, 9)"), 9, "max is variadic")
        expectClose(number("clamp(15, 0, 10)"), 10, "clamp upper")
        expectClose(number("clamp(-5, 0, 10)"), 0, "clamp lower")
    }

    static func testRandomIsInjectable() {
        expectClose(number("random()", random: { 0.25 }), 0.25, "random is the injected source")
        expectClose(number("2 + random() * 4", random: { 0.5 }), 4, "random composes")
    }

    // MARK: - Short circuit

    /// Guards like `self.state == 'grounded' && world.display.workArea.left < x`
    /// rely on the left side gating the right.
    static func testConjunctionShortCircuits() {
        var rightSideEvaluated = false
        let expression = try! CompanionExpression.compile("#{false && random() > 0}")
        _ = expression.evaluateBool(bag([:]), random: {
            rightSideEvaluated = true
            return 1
        })
        expect(!rightSideEvaluated, "&& must not evaluate its right side when the left is false")

        var disjunctionRight = false
        let disjunction = try! CompanionExpression.compile("#{true || random() > 0}")
        _ = disjunction.evaluateBool(bag([:]), random: {
            disjunctionRight = true
            return 1
        })
        expect(!disjunctionRight, "|| must not evaluate its right side when the left is true")
    }

    // MARK: - A realistic pack condition

    static func testRealisticBehaviorCondition() {
        let source = "#{self.state == 'grounded' && mimo.mood != 'deepWork' && mimo.focusMinutes < 25}"
        let expression = try! CompanionExpression.compile(source)

        expect(expression.evaluateBool(bag([
            "self.state": .text("grounded"),
            "mimo.mood": .text("idle"),
            "mimo.focusMinutes": .number(3),
        ])), "roaming is allowed when idle and grounded")

        expect(!expression.evaluateBool(bag([
            "self.state": .text("grounded"),
            "mimo.mood": .text("deepWork"),
            "mimo.focusMinutes": .number(3),
        ])), "roaming is gated off during deep work")

        expect(!expression.evaluateBool(bag([
            "self.state": .text("airborne"),
            "mimo.mood": .text("idle"),
            "mimo.focusMinutes": .number(3),
        ])), "roaming is gated off while airborne")
    }

    static func main() {
        testArithmetic()
        testDivisionByZeroIsContained()
        testComparisonAndLogic()
        testTernary()
        testVariables()
        testMissingValueIsZeroNotACrash()
        testUnknownVariableIsRejectedAtCompileTime()
        testUnknownFunctionIsRejected()
        testArgumentCountIsChecked()
        testMalformedExpressionsAreRejected()
        testLanguageHasNoEscapeHatches()
        testEvaluationModeIsCarried()
        testBuiltins()
        testRandomIsInjectable()
        testConjunctionShortCircuits()
        testRealisticBehaviorCondition()
        print("companion expression: all assertions passed")
    }
}
