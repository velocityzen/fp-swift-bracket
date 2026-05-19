import Testing
@testable import FPBracket

private enum TestError: Error, Equatable { case fail }

private final class CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private func makeBracket<R>(
    _ tag: String,
    log: CallLog,
    resource: R
) -> Bracket<TestError, R> {
    Bracket(
        acquire: {
            log.record("acquire(\(tag))"); return .success(resource)
        },
        dispose: { _ in
            log.record("dispose(\(tag))"); return .success(())
        }
    )
}

@Suite("Bracket do-notation")
struct BracketDoTests {

    @Test("bind starts a chain and accumulates resources into a tuple")
    func bindAccumulates() {
        let log = CallLog()
        let pipeline = BracketDo<TestError>()
            .bind { makeBracket("a", log: log, resource: 1) }
            .bind { _ in makeBracket("b", log: log, resource: "two") }
            .let { _, _ in 3.14 }

        let result = pipeline { tuple in
            let (a, b, c) = tuple
            return Result<String, TestError>.success("a=\(a) b=\(b) c=\(c)")
        }

        #expect(result == .success("a=1 b=two c=3.14"))
        #expect(
            log.events == [
                "acquire(a)", "acquire(b)",
                "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("let on empty Do chain seeds a pure value")
    func letSeeds() {
        let pipeline = BracketDo<TestError>().let { 42 }
        let result = pipeline { v in Result<Int, TestError>.success(v) }
        #expect(result == .success(42))
    }

    @Test("bind short-circuits when a step's acquire fails")
    func bindShortCircuits() {
        let log = CallLog()
        let pipeline = BracketDo<TestError>()
            .bind { makeBracket("a", log: log, resource: 1) }
            .bind { _ -> Bracket<TestError, Int> in
                Bracket(
                    acquire: {
                        log.record("acquire(b)"); return .failure(.fail)
                    },
                    dispose: { _ in .success(()) }
                )
            }
            .let { _, _ in "unused" }

        let result = pipeline { _ in Result<Int, TestError>.success(0) }
        #expect(result == .failure(.fail))
        #expect(log.events == ["acquire(a)", "acquire(b)", "dispose(a)"])
    }

    @Test("4-step chain accumulates a 4-tuple")
    func fourStepChain() {
        let log = CallLog()
        let pipeline = BracketDo<TestError>()
            .bind { makeBracket("a", log: log, resource: 1) }
            .bind { _ in makeBracket("b", log: log, resource: 2) }
            .bind { _, _ in makeBracket("c", log: log, resource: 3) }
            .let { a, b, c in a + b + c }

        let result = pipeline { tuple in
            let (_, _, _, sum) = tuple
            return Result<Int, TestError>.success(sum)
        }

        #expect(result == .success(6))
    }
}
