import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case cancelled
    case disposeFailed
}

private actor CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

/// One-shot signal: lets a test wait until a task reaches a suspension point
/// before cancelling it, so cancellation lands deterministically.
private actor Signal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        fired = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Suspends until the current task is cancelled (or a minute passes).
private func suspendUntilCancelled() async {
    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
}

private func makeBracket(
    _ tag: String,
    log: CallLog
) -> BracketAsync<String, TestError> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))")
            return .success(tag)
        },
        dispose: { r in
            await log.record("dispose(\(r))")
            return .success(())
        }
    )
}

/// A bracket whose acquire blocks until cancelled, then fails.
private func blockingBracket(
    _ tag: String,
    log: CallLog,
    started: Signal
) -> BracketAsync<String, TestError> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))")
            await started.fire()
            await suspendUntilCancelled()
            return .failure(.cancelled)
        },
        dispose: { r in
            await log.record("dispose(\(r))")
            return .success(())
        }
    )
}

@Suite("BracketAsync cancellation")
struct BracketAsyncCancellationTests {

    // MARK: - release guarantees

    @Test("cancelling during body still releases exactly once, in the cancelled task")
    func cancelDuringBody() async {
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<String, TestError>(
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
                return Result<Int, TestError>.failure(.cancelled)
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

    // MARK: - uncancellableDispose

    @Test("uncancellableDispose escapes cancellation; cancellation-aware cleanup completes")
    func uncancellableDisposeCompletes() async {
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<String, TestError>(
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
                return Result<Int, TestError>.success(1)
            }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .success(1))
        #expect(await log.snapshot() == ["dispose(a, cancelled: false)", "slept"])
    }

    @Test("uncancellableDispose behaves like dispose without cancellation; its failure wins")
    func uncancellableDisposeFailure() async {
        let log = CallLog()
        let bracket = BracketAsync<String, TestError>(
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
            return Result<Int, TestError>.success(1)
        }

        #expect(result == .failure(.disposeFailed))
        #expect(await log.snapshot() == ["acquire", "use", "dispose(a)"])
    }

    @Test("uncancellableDispose skips dispose when acquire fails")
    func uncancellableDisposeAcquireFails() async {
        let log = CallLog()
        let bracket = BracketAsync<String, TestError>(
            acquire: { .failure(.cancelled) },
            uncancellableDispose: { _ in
                await log.record("dispose")
                return .success(())
            }
        )

        let result = await bracket { _ in Result<Int, TestError>.success(1) }

        #expect(result == .failure(.cancelled))
        #expect(await log.snapshot() == [])
    }

    @Test("in a flatMap mix, only the uncancellable dispose escapes cancellation")
    func uncancellableDisposeInFlatMap() async {
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let outer = BracketAsync<String, TestError>(
                acquire: { .success("outer") },
                uncancellableDispose: { r in
                    await log.record("dispose(\(r), cancelled: \(Task.isCancelled))")
                    return .success(())
                }
            )
            let inner = BracketAsync<String, TestError>(
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
                return Result<Int, TestError>.failure(.cancelled)
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

    // MARK: - composition under cancellation

    @Test("cancelling during flatMap's inner acquire releases the outer resource")
    func cancelDuringFlatMapInnerAcquire() async {
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let bracket = makeBracket("outer", log: log)
                .flatMap { _ in blockingBracket("inner", log: log, started: started) }
            return await bracket { _ in
                await log.record("use")
                return Result<Int, TestError>.success(0)
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
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let bracket = makeBracket("outer", log: log)
                .flatMap { _ in makeBracket("inner", log: log) }
            return await bracket { _ in
                await started.fire()
                await suspendUntilCancelled()
                return Result<Int, TestError>.failure(.cancelled)
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
        let log = CallLog()
        let started = Signal()

        let task = Task {
            let bracket = [
                makeBracket("a", log: log),
                makeBracket("b", log: log),
                blockingBracket("c", log: log, started: started),
                makeBracket("d", log: log),
            ].sequence()
            return await bracket { _ in
                await log.record("use")
                return Result<Int, TestError>.success(0)
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

    // MARK: - fromTask forwards cancellation

    @Test("fromTask (typed Result) cancels its task when the caller is cancelled")
    func fromTaskTypedForwardsCancellation() async {
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<Bool, TestError>.fromTask {
                Task {
                    await started.fire()
                    await suspendUntilCancelled()
                    return .success(Task.isCancelled)
                }
            }
            return await bracket { v in Result<Bool, TestError>.success(v) }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .success(true))
    }

    @Test("fromTask (throwing) surfaces CancellationError when the caller is cancelled")
    func fromTaskThrowingForwardsCancellation() async {
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<Int, Error>.fromTask {
                Task {
                    await started.fire()
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    return 1
                }
            }
            return await bracket { v in Result<Int, Error>.success(v) }
        }

        await started.wait()
        task.cancel()

        switch await task.value {
            case .success:
                Issue.record("expected CancellationError")
            case .failure(let error):
                #expect(error is CancellationError)
        }
    }

    @Test("fromTask (non-failing) cancels its task when the caller is cancelled")
    func fromTaskNeverForwardsCancellation() async {
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<Bool, Never>.fromTask {
                Task {
                    await started.fire()
                    await suspendUntilCancelled()
                    return Task.isCancelled
                }
            }
            return await bracket { v in Result<Bool, Never>.success(v) }
        }

        await started.wait()
        task.cancel()

        #expect(await task.value == .success(true))
    }

    @Test("fromTask cancels its task immediately when the caller is already cancelled")
    func fromTaskAlreadyCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let bracket = BracketAsync<Bool, Never>.fromTask {
                Task {
                    await suspendUntilCancelled()
                    return Task.isCancelled
                }
            }
            return await bracket { v in Result<Bool, Never>.success(v) }
        }

        #expect(await task.value == .success(true))
    }
}
