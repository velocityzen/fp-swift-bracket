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

/// Suspends until the current task is cancelled (or a minute passes).
func suspendUntilCancelled() async {
    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
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
