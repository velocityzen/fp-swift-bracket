import Testing
@testable import FPBracket

@Suite("BracketAsync uncancellableDispose")
struct BracketAsyncUncancellableDisposeTests {

    // MARK: - uncancellableDispose

    @Test("uncancellableDispose escapes cancellation; cancellation-aware cleanup completes")
    func uncancellableDisposeCompletes() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<String, CancellationTestError>(
                acquire: { .success("a") },
                uncancellableDispose: { r in
                    await log.record("dispose(\(r), cancelled: \(Task.isCancelled))")
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000)
                        await log.record("slept")
                    } catch {
                        await log.record("sleep interrupted")
                    }
                    return .success(())
                }
            )
            return await bracket { _ in
                await started.fire()
                await suspendUntilCancelled()
                return Result<Int, CancellationTestError>.success(1)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .success(1))
        #expect(await log.snapshot() == ["dispose(a, cancelled: false)", "slept"])
    }

    @Test("uncancellableDispose behaves like dispose without cancellation; its failure wins")
    func uncancellableDisposeFailure() async {
        let log = CancellationLog()
        let bracket = BracketAsync<String, CancellationTestError>(
            acquire: {
                await log.record("acquire")
                return .success("a")
            },
            uncancellableDispose: { r in
                await log.record("dispose(\(r))")
                return .failure(.disposeFailed)
            }
        )

        let result = await bracket { _ in
            await log.record("use")
            return Result<Int, CancellationTestError>.success(1)
        }

        #expect(result == .failure(.disposeFailed))
        #expect(await log.snapshot() == ["acquire", "use", "dispose(a)"])
    }

    @Test("uncancellableDispose skips dispose when acquire fails")
    func uncancellableDisposeAcquireFails() async {
        let log = CancellationLog()
        let bracket = BracketAsync<String, CancellationTestError>(
            acquire: { .failure(.cancelled) },
            uncancellableDispose: { _ in
                await log.record("dispose")
                return .success(())
            }
        )

        let result = await bracket { _ in Result<Int, CancellationTestError>.success(1) }

        #expect(result == .failure(.cancelled))
        #expect(await log.snapshot() == [])
    }

    @Test("in a flatMap mix, only the uncancellable dispose escapes cancellation")
    func uncancellableDisposeInFlatMap() async {
        let log = CancellationLog()
        let started = Signal()

        let task = Task {
            let outer = BracketAsync<String, CancellationTestError>(
                acquire: { .success("outer") },
                uncancellableDispose: { r in
                    await log.record("dispose(\(r), cancelled: \(Task.isCancelled))")
                    return .success(())
                }
            )
            let inner = BracketAsync<String, CancellationTestError>(
                acquire: { .success("inner") },
                dispose: { r in
                    await log.record("dispose(\(r), cancelled: \(Task.isCancelled))")
                    return .success(())
                }
            )
            let bracket = outer.flatMap { _ in inner }
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
                "dispose(inner, cancelled: true)",
                "dispose(outer, cancelled: false)",
            ]
        )
    }
}
