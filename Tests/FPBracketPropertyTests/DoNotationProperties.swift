// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

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
                return winner(inner: innerOutcome, outer: outerOutcome, log: log)
        }
    }

    enum DoGen {
        static func step(_ policy: Policy) -> Gen<DoStep> {
            .oneOf(
                BracketGen.part(policy).map { DoStep.bind($0) },
                BracketGen.value.map { DoStep.let($0) }
            )
        }

        /// Every arity the generated chains have: the flattening overloads up
        /// to 10 values, then the nested ones. Hegel keeps arrays short, so the
        /// long chains get their own branch.
        static func steps(_ policy: Policy) -> Gen<[DoStep]> {
            .oneOf(
                .array(of: step(policy), count: 1...maxDoSteps),
                .array(of: step(policy), count: 10...maxDoSteps)
            )
        }
    }

    /// Runs the model of a do-notation chain, and records what it went through.
    func modelDo(
        _ tc: TestCase,
        _ steps: [DoStep],
        body: Result<Int, Code>
    ) throws -> (Result<Int, Code>, ModelLog) {
        let log = ModelLog()
        let expected = modelCall(body: body, log: log) { runDo(steps[...], [], log: log, $0) }
        try recordReach(tc, nil, log, constructors: false)
        if log.bodyRan, steps.count > 10 {
            try tc.event(Reach.pastFlattening)
        }
        return (expected, log)
    }

    @Suite("Do-notation properties", .hegel)
    struct DoNotationProperties {
        /// What both properties claim.
        static let reaching = [
            Reach.bodyRan, Reach.pastFlattening, Reach.rollback, Reach.releasesFailed,
            Reach.innerBeatOuter,
        ]

        /// `BracketDo` chains of any length, mixing `bind` and `let`, acquire and
        /// release like the nested `flatMap`s they stand for, and give every
        /// value to the body, in order.
        ///
        /// Reach: the body getting more than 10 values, a rollback, and
        /// release failures meeting.
        @Test(.hegel(testCases: testCases(1_000)))
        func doChainsMatchTheModel() throws {
            try property(reaching: Self.reaching) { tc in
                let policy = try tc.draw(BracketGen.policy, named: "policy")
                let steps = try tc.draw(DoGen.steps(policy), named: "steps")
                let body = try tc.draw(BracketGen.body, named: "body")
                let (expected, modelLog) = try modelDo(tc, steps, body: body)

                let log = Log()
                let result = call(doChain(steps, log: log), body: body, log: log)
                #expect(result == expected)
                #expect(log.entries == modelLog.entries)
            }
        }

        /// The same for `BracketAsyncDo`.
        @Test(.hegel(testCases: testCases(500)))
        func asyncDoChainsMatchTheModel() async throws {
            try await property(reaching: Self.reaching) { tc in
                let policy = try tc.draw(BracketGen.policy, named: "policy")
                let steps = try tc.draw(DoGen.steps(policy), named: "steps")
                let body = try tc.draw(BracketGen.body, named: "body")
                let (expected, modelLog) = try modelDo(tc, steps, body: body)

                let log = Log()
                let result = await call(doChainAsync(steps, log: log), body: body, log: log)
                #expect(result == expected)
                #expect(log.entries == modelLog.entries)
            }
        }
    }

#endif
