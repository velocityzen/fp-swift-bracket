import Testing
@testable import FPBracket

@Suite("BracketAsync cancellation")
struct BracketAsyncCancellationTests {

    // MARK: - release guarantees

    @Test("cancelling during body still releases exactly once, in the cancelled task")
    func cancelDuringBody() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<String, CancellationTestError>(
                acquire: {
                    await log.record("acquire")
                    return .success("a")
                },
                dispose: { _ in
                    await log.record("dispose(cancelled: \(Task.isCancelled))")
                    return .success(())
                }
            )
            return await bracket { _ in
                await started.fire()
                await suspendUntilCancelled()
                await log.record("use(cancelled: \(Task.isCancelled))")
                return Result<Int, CancellationTestError>.failure(.cancelled)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .failure(.cancelled))
        #expect(
            await log.snapshot() == [
                "acquire",
                "use(cancelled: true)",
                "dispose(cancelled: true)",
            ]
        )
    }

    // MARK: - composition under cancellation

    @Test("cancelling during flatMap's inner acquire releases the outer resource")
    func cancelDuringFlatMapInnerAcquire() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let bracket = loggingBracket("outer", log: log)
                .flatMap { _ in blockingBracket("inner", log: log, started: started) }
            return await bracket { _ in
                await log.record("use")
                return Result<Int, CancellationTestError>.success(0)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .failure(.cancelled))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "dispose(outer)",
            ]
        )
    }

    @Test("cancelling during flatMap's body releases inner then outer")
    func cancelDuringFlatMapBody() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let bracket = loggingBracket("outer", log: log)
                .flatMap { _ in loggingBracket("inner", log: log) }
            return await bracket { _ in
                await started.fire()
                await suspendUntilCancelled()
                return Result<Int, CancellationTestError>.failure(.cancelled)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .failure(.cancelled))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "dispose(inner)",
                "dispose(outer)",
            ]
        )
    }

    @Test("cancelling during sequence acquire releases acquired resources in reverse")
    func cancelDuringSequenceAcquire() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let bracket = [
                loggingBracket("a", log: log),
                loggingBracket("b", log: log),
                blockingBracket("c", log: log, started: started),
                loggingBracket("d", log: log),
            ].sequence()
            return await bracket { _ in
                await log.record("use")
                return Result<Int, CancellationTestError>.success(0)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .failure(.cancelled))
        #expect(
            await log.snapshot() == [
                "acquire(a)",
                "acquire(b)",
                "acquire(c)",
                "dispose(b)",
                "dispose(a)",
            ]
        )
    }
}
