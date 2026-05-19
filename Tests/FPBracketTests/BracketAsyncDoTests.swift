import Testing
@testable import FPBracket

private enum TestError: Error, Equatable { case fail }

private actor AsyncLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private func makeAsyncBracket<R>(
    _ tag: String,
    log: AsyncLog,
    resource: R
) -> BracketAsync<TestError, R> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))"); return .success(resource)
        },
        dispose: { _ in
            await log.record("dispose(\(tag))"); return .success(())
        }
    )
}

@Suite("BracketAsync do-notation")
struct BracketAsyncDoTests {

    @Test("bind starts an async chain and accumulates resources into a tuple")
    func bindAccumulates() async {
        let log = AsyncLog()
        let pipeline = BracketAsyncDo<TestError>()
            .bind { makeAsyncBracket("a", log: log, resource: 1) }
            .bind { _ in makeAsyncBracket("b", log: log, resource: "two") }
            .let { _, _ in 3.14 }

        let result = await pipeline { tuple in
            let (a, b, c) = tuple
            return Result<String, TestError>.success("a=\(a) b=\(b) c=\(c)")
        }

        #expect(result == .success("a=1 b=two c=3.14"))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "acquire(b)",
                "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("bind short-circuits when a step's acquire fails")
    func bindShortCircuits() async {
        let log = AsyncLog()
        let pipeline = BracketAsyncDo<TestError>()
            .bind { makeAsyncBracket("a", log: log, resource: 1) }
            .bind { _ -> BracketAsync<TestError, Int> in
                BracketAsync(
                    acquire: {
                        await log.record("acquire(b)"); return .failure(.fail)
                    },
                    dispose: { _ in .success(()) }
                )
            }

        let result = await pipeline { _ in Result<Int, TestError>.success(0) }
        #expect(result == .failure(.fail))
        #expect(await log.snapshot() == ["acquire(a)", "acquire(b)", "dispose(a)"])
    }
}
