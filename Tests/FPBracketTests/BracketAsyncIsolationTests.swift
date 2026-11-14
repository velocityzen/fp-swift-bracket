import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case acquireFailed
}

@MainActor
private final class Counter {
    var value = 0
}

/// A resource that can't cross to another task.
private final class Handle {
    var closed = false
}

@MainActor
private let mainActorBracket = BracketAsync<Int, TestError>(
    acquire: { .success(1) },
    dispose: { _ in .success(()) }
)

@Suite("BracketAsync isolation")
@MainActor
struct BracketAsyncIsolationTests {

    @Test("a main-actor-isolated bracket can be called from the main actor")
    func callsMainActorIsolatedBracket() async {
        let result = await mainActorBracket { r in .success(r + 1) }
        #expect(result == .success(2))
    }

    @Test("acquire, body, and dispose run on the caller's actor")
    func runsOnCallersActor() async {
        let counter = Counter()
        let bracket = BracketAsync<Int, TestError>(
            acquire: {
                MainActor.assertIsolated()
                counter.value += 1
                return .success(counter.value)
            },
            dispose: { _ in
                MainActor.assertIsolated()
                counter.value += 10
                return .success(())
            }
        )
        .map { $0 * 2 }
        .flatMap { r in .of(r) }

        let result = await bracket { r in
            MainActor.assertIsolated()
            counter.value += 100
            return .success(r)
        }

        #expect(result == .success(2))
        #expect(counter.value == 111)
    }

    @Test(
        "uncancellableDispose runs on the caller's actor, with a non-Sendable resource, shielded from the caller's cancellation"
    )
    func uncancellableDisposeRunsOnCallersActor() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var seen: [String] = []
            let bracket = BracketAsync<Handle, TestError>(
                acquire: { .success(Handle()) },
                uncancellableDispose: { handle in
                    MainActor.assertIsolated()
                    seen.append("dispose, cancelled: \(Task.isCancelled)")
                    handle.closed = true
                    return .success(())
                }
            )
            var handle: Handle?
            let result = await bracket { h in
                handle = h
                return .success(1)
            }
            seen.append("after, cancelled: \(Task.isCancelled)")
            return (result, handle?.closed == true, seen)
        }

        let (result, closed, seen) = await task.value
        #expect(result == .success(1))
        #expect(closed)
        #expect(seen == ["dispose, cancelled: false", "after, cancelled: true"])
    }

    @Test("a sequenced array of brackets runs on the caller's actor")
    func sequenceRunsOnCallersActor() async {
        let counter = Counter()
        let bracket = [1, 2, 3].map { n in
            BracketAsync<Int, TestError>(
                acquire: {
                    MainActor.assertIsolated()
                    counter.value += n
                    return .success(n)
                },
                dispose: { _ in
                    MainActor.assertIsolated()
                    return .success(())
                }
            )
        }
        .sequence()

        let result = await bracket { rs in .success(rs.reduce(0, +)) }

        #expect(result == .success(6))
        #expect(counter.value == 6)
    }
}
