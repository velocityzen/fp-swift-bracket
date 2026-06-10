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
) -> BracketAsync<R, TestError> {
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
            .bind { _ -> BracketAsync<Int, TestError> in
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

    @Test("bind chain flattens through every arity up to 10 elements")
    func bindChainAllArities() async {
        let log = AsyncLog()
        let pipeline = BracketAsyncDo<TestError>()
            .bind { makeAsyncBracket("r1", log: log, resource: 1) }
            .bind { _ in makeAsyncBracket("r2", log: log, resource: 2) }
            .bind { _, _ in makeAsyncBracket("r3", log: log, resource: 3) }
            .bind { _, _, _ in makeAsyncBracket("r4", log: log, resource: 4) }
            .bind { _, _, _, _ in makeAsyncBracket("r5", log: log, resource: 5) }
            .bind { _, _, _, _, _ in makeAsyncBracket("r6", log: log, resource: 6) }
            .bind { _, _, _, _, _, _ in makeAsyncBracket("r7", log: log, resource: 7) }
            .bind { _, _, _, _, _, _, _ in makeAsyncBracket("r8", log: log, resource: 8) }
            .bind { _, _, _, _, _, _, _, _ in makeAsyncBracket("r9", log: log, resource: 9) }
            .bind { _, _, _, _, _, _, _, _, _ in makeAsyncBracket("r10", log: log, resource: 10) }

        let result = await pipeline { tuple in
            let (a, b, c, d, f, g, h, i, j, k) = tuple
            return Result<[Int], TestError>.success([a, b, c, d, f, g, h, i, j, k])
        }

        #expect(result == .success(Array(1...10)))
        let acquires = (1...10).map { "acquire(r\($0))" }
        let disposes = (1...10).reversed().map { "dispose(r\($0))" }
        #expect(await log.snapshot() == acquires + disposes)
    }

    @Test("let chain flattens through every arity up to 10 elements")
    func letChainAllArities() async {
        let pipeline = BracketAsyncDo<TestError>()
            .let { 1 }
            .let { a in a + 1 }
            .let { _, b in b + 1 }
            .let { _, _, c in c + 1 }
            .let { _, _, _, d in d + 1 }
            .let { _, _, _, _, f in f + 1 }
            .let { _, _, _, _, _, g in g + 1 }
            .let { _, _, _, _, _, _, h in h + 1 }
            .let { _, _, _, _, _, _, _, i in i + 1 }
            .let { _, _, _, _, _, _, _, _, j in j + 1 }

        let result = await pipeline { tuple in
            let (a, b, c, d, f, g, h, i, j, k) = tuple
            return Result<[Int], TestError>.success([a, b, c, d, f, g, h, i, j, k])
        }

        #expect(result == .success(Array(1...10)))
    }
}
