import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case acquireFailed
    case useFailed
    case disposeFailed
    case innerAcquireFailed
    case innerDisposeFailed
}

private actor CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private func makeBracket(
    _ tag: String,
    log: CallLog,
    resource: Int
) -> BracketAsync<Int, TestError> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))")
            return .success(resource)
        },
        dispose: { r in
            await log.record("dispose(\(tag), \(r))")
            return .success(())
        }
    )
}

@Suite("BracketAsync.flatMap")
struct BracketAsyncFlatMapTests {

    // MARK: - flatMap

    @Test("flatMap nests two brackets; release order is inner-then-outer")
    func flatMapNestsScopes() async {
        let log = CallLog()
        let outer = makeBracket("outer", log: log, resource: 1)
        let composed = outer.flatMap { _ in
            makeBracket("inner", log: log, resource: 2)
        }

        let result = await composed { r in
            await log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(2))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "use(2)",
                "dispose(inner, 2)",
                "dispose(outer, 1)",
            ]
        )
    }

    @Test("flatMap releases outer when inner acquire fails")
    func flatMapReleasesOuterOnInnerAcquireFailure() async {
        let log = CallLog()
        let outer = makeBracket("outer", log: log, resource: 1)
        let failingInner = BracketAsync<Int, TestError>(
            acquire: {
                await log.record("acquire(inner)")
                return .failure(.innerAcquireFailed)
            },
            dispose: { r in
                await log.record("dispose(inner, \(r))")
                return .success(())
            }
        )

        let composed = outer.flatMap { _ in failingInner }
        let result = await composed { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.innerAcquireFailed))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "dispose(outer, 1)",
            ]
        )
    }

    @Test("flatMap still releases outer when inner dispose fails; inner error wins")
    func flatMapInnerDisposeFailureWins() async {
        let log = CallLog()
        let outer = BracketAsync<Int, TestError>(
            acquire: {
                await log.record("acquire(outer)")
                return .success(1)
            },
            dispose: { r in
                await log.record("dispose(outer, \(r))")
                return .failure(.disposeFailed)
            }
        )
        let inner = BracketAsync<Int, TestError>(
            acquire: {
                await log.record("acquire(inner)")
                return .success(2)
            },
            dispose: { r in
                await log.record("dispose(inner, \(r))")
                return .failure(.innerDisposeFailed)
            }
        )

        let composed = outer.flatMap { _ in inner }
        let result = await composed { r in Result<Int, TestError>.success(r) }

        #expect(result == .failure(.innerDisposeFailed))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "dispose(inner, 2)",
                "dispose(outer, 1)",
            ]
        )
    }

    @Test("flatMap returns outer dispose failure when inner releases cleanly")
    func flatMapOuterDisposeFailure() async {
        let log = CallLog()
        let outer = BracketAsync<Int, TestError>(
            acquire: {
                await log.record("acquire(outer)")
                return .success(1)
            },
            dispose: { r in
                await log.record("dispose(outer, \(r))")
                return .failure(.disposeFailed)
            }
        )

        let composed = outer.flatMap { _ in makeBracket("inner", log: log, resource: 2) }
        let result = await composed { r in Result<Int, TestError>.success(r) }

        #expect(result == .failure(.disposeFailed))
        #expect(
            await log.snapshot() == [
                "acquire(outer)",
                "acquire(inner)",
                "dispose(inner, 2)",
                "dispose(outer, 1)",
            ]
        )
    }
}
