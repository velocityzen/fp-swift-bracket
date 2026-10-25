import Testing
@testable import FPBracket

@Suite("BracketAsync.fromTask cancellation")
struct BracketAsyncFromTaskCancellationTests {

    // MARK: - fromTask forwards cancellation

    @Test("fromTask (typed Result) cancels its task when the caller is cancelled")
    func fromTaskTypedForwardsCancellation() async {
        let started = Signal()

        let task = Task {
            let bracket = BracketAsync<Bool, CancellationTestError>.fromTask {
                Task {
                    await started.fire()
                    await suspendUntilCancelled()
                    return .success(Task.isCancelled)
                }
            }
            return await bracket { v in Result<Bool, CancellationTestError>.success(v) }
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
