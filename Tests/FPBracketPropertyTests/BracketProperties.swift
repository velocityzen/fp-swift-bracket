// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPBracket
    import HegelTesting
    import Testing

    @Suite("Bracket properties", .hegel)
    struct BracketProperties {
        /// Any composition of brackets acquires, runs the body, releases and
        /// fails the way the documented semantics say. A second call does it
        /// all again: a bracket is a recipe, not a resource.
        @Test(.hegel(testCases: 2_000))
        func bracketsMatchTheModel() throws {
            try property { tc in
                let e = try tc.draw(BracketGen.expr, named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)

                let log = Log()
                let b = bracket(e, log: log)
                for run in 1...2 {
                    let start = log.entries.count
                    let result = call(b, body: body, log: log)
                    #expect(result == expected, "call \(run)")
                    #expect(Array(log.entries[start...]) == modelLog.entries, "call \(run)")
                }
            }
        }

        /// The same for `BracketAsync`, with every kind of leaf: plain,
        /// `uncancellableDispose`, `throwing` and `fromTask`.
        @Test(.hegel(testCases: 1_000))
        func asyncBracketsMatchTheModel() async throws {
            try await property { tc in
                let e = try tc.draw(BracketGen.expr, named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)

                let log = Log()
                let b = bracketAsync(e, log: log)
                for run in 1...2 {
                    let start = log.entries.count
                    let result = await call(b, body: body, log: log)
                    #expect(result == expected, "call \(run)")
                    #expect(Array(log.entries[start...]) == modelLog.entries, "call \(run)")
                }
                // Cancellation was never involved.
                #expect(log.disposes.allSatisfy { !$0.sawCancellation })
            }
        }

        /// Cancelling the caller at any point changes nothing but what dispose
        /// sees: every resource acquired is still released, once, in order, and
        /// the call returns only after the cleanup. A plain or throwing dispose
        /// runs in the cancelled task and sees it; an `uncancellableDispose`
        /// does not.
        @Test(.hegel(testCases: 1_000))
        func cancellingTheCallerStillReleasesEverything() async throws {
            try await property { tc in
                let e = try tc.draw(BracketGen.expr, named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)
                // Each log entry is a checkpoint: cancel after any of them, or
                // before the first.
                let run = try await tc.withRandomCancellation(
                    checkpoints: 0...modelLog.entries.count
                ) { cancellation in
                    let log = Log(onEntry: { cancellation.checkpoint($0) })
                    let result = await call(bracketAsync(e, log: log), body: body, log: log)
                    return (result, log)
                }
                let (result, log) = run.value
                let entries = log.entries

                #expect(result == expected)
                #expect(entries == modelLog.entries)
                for dispose in log.disposes {
                    // `event` entries came before this dispose.
                    let cancelled = run.isCancelled(after: dispose.event)
                    switch dispose.kind {
                        case .plain, .throwing:
                            #expect(
                                dispose.sawCancellation == cancelled,
                                "a \(dispose.kind) dispose after \(dispose.event) events"
                            )
                        case .uncancellable:
                            #expect(!dispose.sawCancellation, "an uncancellable dispose saw it")
                    }
                }
                // Structured: nothing runs on after the call returns. Without a
                // tolerance the system may coalesce the timer and sleep longer.
                try? await Task.sleep(for: .milliseconds(1), tolerance: .zero)
                #expect(log.entries.count == entries.count, "work went on after the call returned")
            }
        }
    }

    extension BracketProperties {
        /// `sequence()` and `traverse` behave like the equivalent `flatMap`
        /// chain, as their documentation says: the same acquires and releases,
        /// and the same failure wins. Both sides are real brackets, with many
        /// failing releases.
        @Test(.hegel(testCases: 500))
        func sequenceIsTheFlatMapChain() async throws {
            try await property { tc in
                // Any brackets; or only acquire/dispose pairs, which `sequence()`
                // runs on a separate path, often enough for its release
                // failures to meet.
                let es = try tc.draw(
                    .oneOf(
                        .array(of: BracketGen.part),
                        .array(of: BracketGen.part, count: 10...Int.max),
                        .array(of: BracketGen.leaf)
                    ),
                    named: "brackets"
                )
                let body = try tc.draw(BracketGen.body, named: "body")

                let chainLog = Log()
                let chain = es.reversed().reduce(Bracket<[Int], Code>.of([])) { rest, e in
                    bracket(e, log: chainLog).flatMap { value in rest.map { [value] + $0 } }
                }
                let expected = call(chain.map(combined), body: body, log: chainLog)

                let log = Log()
                let sequenced = es.map { bracket($0, log: log) }.sequence().map(combined)
                #expect(call(sequenced, body: body, log: log) == expected)
                #expect(log.entries == chainLog.entries)

                let asyncChainLog = Log()
                let asyncChain = es.reversed().reduce(BracketAsync<[Int], Code>.of([])) { rest, e in
                    bracketAsync(e, log: asyncChainLog).flatMap { value in rest.map { [value] + $0 }
                    }
                }
                let asyncExpected = await call(
                    asyncChain.map(combined),
                    body: body,
                    log: asyncChainLog
                )
                let asyncLog = Log()
                let asyncSequenced = es.map { bracketAsync($0, log: asyncLog) }.sequence().map(
                    combined
                )
                #expect(await call(asyncSequenced, body: body, log: asyncLog) == asyncExpected)
                #expect(asyncLog.entries == asyncChainLog.entries)
            }
        }
    }

#endif
