import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case acquireFailed
}

@MainActor
private final class Counter {
    var value = 0
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
