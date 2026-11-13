import FPBracket
import HegelTesting
import Testing

/// One step of a do-notation chain: `bind` a bracket, or `let` a value. Each
/// depends on every value before it.
enum DoStep: Hashable, Sendable, CustomStringConvertible {
    case bind(Expr)
    case `let`(Int)

    var isBind: Bool {
        if case .bind = self { true } else { false }
    }

    var expr: Expr? {
        if case .bind(let e) = self { e } else { nil }
    }

    var constant: Int? {
        if case .let(let k) = self { k } else { nil }
    }

    var description: String {
        switch self {
            case .bind(let e): "bind { \(e) }"
            case .let(let k): "let { +\(k) }"
        }
    }
}

/// A do-notation chain is a left-nested `flatMap` chain:
/// `((s0 ⋈ s1) ⋈ s2) ⋈ …`. The model runs it right-nested,
/// `s0 ⋈ (s1 ⋈ (s2 ⋈ …))`, so the two agreeing also checks that `flatMap`
/// is associative.
func runDo(
    _ steps: ArraySlice<DoStep>,
    _ values: [Int],
    log: ModelLog,
    _ body: @escaping (Int) -> Void
) -> Result<Void, Code> {
    guard let step = steps.first else {
        body(combined(values))
        return .success(())
    }
    switch step {
        case .let(let k):
            return runDo(steps.dropFirst(), values + [combined(values) &+ k], log: log, body)
        case .bind(let e):
            var innerOutcome: Result<Void, Code> = .success(())
            let outerOutcome = run(e, offset: combined(values), log: log) { value in
                innerOutcome = runDo(steps.dropFirst(), values + [value], log: log, body)
            }
            if case .failure = innerOutcome { return innerOutcome }
            return outerOutcome
    }
}

enum DoGen {
    static let step: Gen<DoStep> = .oneOf(
        BracketGen.expr.map { DoStep.bind($0) },
        BracketGen.value.map { DoStep.let($0) }
    )

    /// Every arity the generated chains have: the flattening overloads up
    /// to 10 values, then the nested ones. Hegel keeps arrays short, so the
    /// long chains get their own branch.
    static let steps: Gen<[DoStep]> = .oneOf(
        .array(of: step, count: 1...maxDoSteps),
        .array(of: step, count: 10...maxDoSteps)
    )
}

@Suite("Do-notation properties", .hegel)
struct DoNotationProperties {
    /// `BracketDo` chains of any length, mixing `bind` and `let`, acquire and
    /// release like the nested `flatMap`s they stand for, and give every
    /// value to the body, in order.
    @Test(.hegel(testCases: 1_000))
    func doChainsMatchTheModel() throws {
        try property { tc in
            let steps = try tc.draw(DoGen.steps, named: "steps")
            let body = try tc.draw(BracketGen.body, named: "body")
            let modelLog = ModelLog()
            let scope = runDo(steps[...], [], log: modelLog) {
                modelLog.entries.append("body \($0)")
            }
            let expected = scope.flatMap { body }

            let log = Log()
            let result = call(doChain(steps, log: log), body: body, log: log)
            #expect(result == expected)
            #expect(log.entries == modelLog.entries)
        }
    }

    /// The same for `BracketAsyncDo`.
    @Test(.hegel(testCases: 500))
    func asyncDoChainsMatchTheModel() async throws {
        try await property { tc in
            let steps = try tc.draw(DoGen.steps, named: "steps")
            let body = try tc.draw(BracketGen.body, named: "body")
            let modelLog = ModelLog()
            let scope = runDo(steps[...], [], log: modelLog) {
                modelLog.entries.append("body \($0)")
            }
            let expected = scope.flatMap { body }

            let log = Log()
            let result = await call(doChainAsync(steps, log: log), body: body, log: log)
            #expect(result == expected)
            #expect(log.entries == modelLog.entries)
        }
    }
}
