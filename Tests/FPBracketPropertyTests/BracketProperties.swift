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
        ///
        /// Reach: `Reach.model` — the body after many acquires, a rollback,
        /// every kind of failure precedence, and each of `sequence()`'s paths.
        @Test(.hegel(testCases: testCases(2_000)))
        func bracketsMatchTheModel() throws {
            try property(reaching: Reach.model) { tc in
                let policy = try tc.draw(BracketGen.policy, named: "policy")
                let e = try tc.draw(BracketGen.expression(policy), named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)
                try recordReach(tc, e, modelLog, constructors: false)

                let log = Log()
                let b = bracket(e, log: log)
                #expect(call(b, body: body, log: log) == expected)
                #expect(log.entries == modelLog.entries)

                let start = log.entries.count
                #expect(call(b, body: body, log: log) == expected, "the second call")
                #expect(Array(log.entries[start...]) == modelLog.entries, "the second call")
            }
        }

        /// The same for `BracketAsync`, with every constructor: plain,
        /// `uncancellableDispose`, `throwing`, `fromAcquire` and the three
        /// `fromTask` overloads.
        ///
        /// Reach: `Reach.model`, and every constructor failing.
        @Test(.hegel(testCases: testCases(1_000)))
        func asyncBracketsMatchTheModel() async throws {
            try await property(reaching: Reach.model + Reach.constructors) { tc in
                let policy = try tc.draw(BracketGen.policy, named: "policy")
                let e = try tc.draw(BracketGen.expression(policy), named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)
                try recordReach(tc, e, modelLog, constructors: true)

                let log = Log()
                let b = bracketAsync(e, log: log)
                #expect(await call(b, body: body, log: log) == expected)
                #expect(log.entries == modelLog.entries)

                let start = log.entries.count
                #expect(await call(b, body: body, log: log) == expected, "the second call")
                #expect(Array(log.entries[start...]) == modelLog.entries, "the second call")
                // Cancellation was never involved.
                #expect(log.disposes.allSatisfy { !$0.sawCancellation })
            }
        }

        /// Cancelling the caller at any point changes nothing but what dispose
        /// sees, and what a waiting acquire does: every resource acquired is
        /// still released, once, in order, and the call returns only after
        /// the cleanup. A plain or throwing dispose runs in the cancelled task
        /// and sees it; an `uncancellableDispose` does not. An acquire waiting
        /// for a cancel gets it, in the caller's task or, through
        /// `fromTask`, in the task it made.
        ///
        /// Reach: a cancel before the call starts, a cancelled dispose of
        /// each kind, and a hang of each kind cancelled.
        @Test(.hegel(testCases: testCases(1_000)))
        func cancellingTheCallerStillReleasesEverything() async throws {
            let reaching =
                [Reach.cancelledBeforeStart]
                + LeafKind.allCases.map(Reach.cancelledDispose)
                + FromKind.allCases.map(Reach.hangCancelled)
            try await property(reaching: reaching) { tc in
                let policy = try tc.draw(BracketGen.cancellationPolicy, named: "policy")
                let e = try tc.draw(BracketGen.expression(policy), named: "bracket")
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                let expected = modelCall(e, body: body, log: modelLog)
                try recordReach(tc, e, modelLog, constructors: true)
                // Each log entry is a checkpoint: cancel after any of them, or
                // before the first. A hang waits for the cancel, so it lands
                // by the first hang's entry.
                let lastCheckpoint =
                    modelLog.firstHang.map { $0.entry + 1 } ?? modelLog.entries.count
                let run = try await tc.withRandomCancellation(
                    checkpoints: 0...lastCheckpoint,
                    endsWithin: .seconds(5)
                ) { cancellation in
                    let log = Log(
                        onEntry: { cancellation.checkpoint($0) },
                        cancelLanded: { cancellation.cancelledAt != nil }
                    )
                    let result = await call(bracketAsync(e, log: log), body: body, log: log)
                    // What had happened when the call returned.
                    return (result, log, log.entries)
                }
                let (result, log, entries) = run.value

                #expect(result == expected)
                #expect(entries == modelLog.entries)
                if run.cancelledAt == 0 {
                    try tc.event(Reach.cancelledBeforeStart)
                }
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
                    if cancelled {
                        try tc.event(Reach.cancelledDispose(dispose.kind))
                    }
                }
                if let hang = modelLog.firstHang, run.isCancelled(after: hang.entry + 1) {
                    // Every hang waited after the cancel, so each one got it.
                    #expect(log.probe.started == modelLog.hangs, "hangs that waited")
                    #expect(log.probe.uncancelled == 0, "a hang never got the caller's cancel")
                    try tc.event(Reach.hangCancelled(hang.via))
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
        /// and the same failure wins. Both sides are real brackets.
        ///
        /// Reach: no brackets, and on each of `sequence()`'s paths a rollback
        /// and release failures meeting; the body after many acquires.
        @Test(.hegel(testCases: testCases(1_000)))
        func sequenceIsTheFlatMapChain() async throws {
            let reaching = [
                Reach.emptySequence, Reach.directSequence, Reach.resourceSequence,
                Reach.composedMapErrorResource, Reach.directRollback, Reach.resourceRollback,
                Reach.directReleasesFailed, Reach.resourceReleasesFailed, Reach.innerBeatOuter,
                Reach.deepBody,
            ]
            try await property(reaching: reaching) { tc in
                let policy = try tc.draw(BracketGen.policy, named: "policy")
                // A few brackets of any size; or only acquire/dispose pairs,
                // which `sequence()` runs on a path of its own; or many small
                // ones. The model and
                // the `flatMap` chain nest a call per bracket, and with no
                // failure to stop them early, many large brackets overflow
                // a concurrency thread's stack.
                let es = try tc.draw(
                    .oneOf(
                        .array(of: BracketGen.part(policy), count: 0...10),
                        .array(of: BracketGen.leaf(policy)),
                        .array(of: BracketGen.expression(policy, maxLeaves: 3), count: 10...64)
                    ),
                    named: "brackets"
                )
                let body = try tc.draw(BracketGen.body, named: "body")
                let modelLog = ModelLog()
                _ = modelCall(.sequence(es, traverse: false), body: body, log: modelLog)
                try recordReach(tc, .sequence(es, traverse: false), modelLog, constructors: false)
                try tc.event("brackets", value: Double(es.count))

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
                    bracketAsync(e, log: asyncChainLog).flatMap { value in
                        rest.map { [value] + $0 }
                    }
                }
                let asyncExpected = await call(
                    asyncChain.map(combined),
                    body: body,
                    log: asyncChainLog
                )
                let asyncLog = Log()
                let asyncSequenced = es.map { bracketAsync($0, log: asyncLog) }.sequence()
                    .map(combined)
                #expect(await call(asyncSequenced, body: body, log: asyncLog) == asyncExpected)
                #expect(asyncLog.entries == asyncChainLog.entries)
            }
        }
    }

#endif
