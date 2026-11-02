import Testing
@testable import FPBracket

// Shared helpers for the BracketAsync cancellation suites.

enum CancellationTestError: Error, Equatable {
    case cancelled
    case disposeFailed
}

actor CancellationLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

/// One-shot signal: lets a test wait until a task reaches a suspension point
/// before cancelling it, so cancellation lands deterministically.
actor Signal {
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

/// How long, in minutes, a test that waits on a cancellation may run.
private let hangLimitMinutes = 10

extension Trait where Self == TimeLimitTrait {
    /// Fails a test that would hang, rather than fail, if a cancellation
    /// were lost.
    ///
    /// It only has to catch a hang, so it is generous: the limit counts wall
    /// clock time, and simulators under CI can stall for well over a minute.
    static var hangGuard: Self { .timeLimit(.minutes(hangLimitMinutes)) }
}

/// Suspends until the current task is cancelled, for an operation that only
/// a cancellation may end.
///
/// A long sleep is not enough: simulators under CI can stall for longer than
/// the sleep, which then finishes before the cancellation arrives.
///
/// If the cancellation never comes, it gives up once the `hangGuard` limit
/// has passed, and the test fails on what it then sees. The time limit alone
/// would record the failure but not end the test: it cancels the test's own
/// task, which a wait inside an unstructured `Task` never sees, and Swift
/// Testing waits for the test to return. Give every test that waits on this
/// `hangGuard`.
func suspendUntilCancelled() async {
    let deadline = ContinuousClock.now + .seconds(hangLimitMinutes * 60)
    while !Task.isCancelled, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .seconds(10))
    }
}

func loggingBracket(
    _ tag: String,
    log: CancellationLog
) -> BracketAsync<String, CancellationTestError> {
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
func blockingBracket(
    _ tag: String,
    log: CancellationLog,
    started: Signal
) -> BracketAsync<String, CancellationTestError> {
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
