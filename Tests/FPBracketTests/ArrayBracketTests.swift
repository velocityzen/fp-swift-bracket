import Testing
@testable import FPBracket

private enum TestError: Error, Equatable { case acquireFailed }

private final class CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor AsyncLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private func makeBracket(
    _ tag: String,
    log: CallLog,
    resource: Int
) -> Bracket<TestError, Int> {
    Bracket(
        acquire: {
            log.record("acquire(\(tag))"); return .success(resource)
        },
        dispose: { _ in
            log.record("dispose(\(tag))"); return .success(())
        }
    )
}

private func makeAsyncBracket(
    _ tag: String,
    log: AsyncLog,
    resource: Int
) -> BracketAsync<TestError, Int> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))"); return .success(resource)
        },
        dispose: { _ in
            await log.record("dispose(\(tag))"); return .success(())
        }
    )
}

@Suite("Array extensions for Bracket")
struct ArrayBracketTests {

    // MARK: - sequence

    @Test("sequence: acquires left-to-right, releases right-to-left")
    func sequenceLifecycle() {
        let log = CallLog()
        let combined = [
            makeBracket("a", log: log, resource: 1),
            makeBracket("b", log: log, resource: 2),
            makeBracket("c", log: log, resource: 3),
        ].sequence()

        let result = combined { resources in
            log.record("use(\(resources))")
            return Result<Int, TestError>.success(resources.reduce(0, +))
        }

        #expect(result == .success(6))
        #expect(
            log.events == [
                "acquire(a)", "acquire(b)", "acquire(c)",
                "use([1, 2, 3])",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("sequence: previously acquired are released when a later acquire fails")
    func sequenceReleasesOnAcquireFailure() {
        let log = CallLog()
        let brackets: [Bracket<TestError, Int>] = [
            makeBracket("a", log: log, resource: 1),
            Bracket(
                acquire: {
                    log.record("acquire(b)")
                    return .failure(.acquireFailed)
                },
                dispose: { _ in
                    log.record("dispose(b)"); return .success(())
                }
            ),
            makeBracket("c", log: log, resource: 3),
        ]

        let combined = brackets.sequence()
        let result = combined { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.acquireFailed))
        #expect(
            log.events == [
                "acquire(a)",
                "acquire(b)",
                "dispose(a)",
            ]
        )
    }

    @Test("sequence on empty array yields an empty resource list")
    func sequenceEmpty() {
        let empty: [Bracket<TestError, Int>] = []
        let combined = empty.sequence()
        let result = combined { resources in
            Result<Int, TestError>.success(resources.count)
        }
        #expect(result == .success(0))
    }

    // MARK: - traverse

    @Test("traverse maps elements to brackets and sequences them")
    func traverseLifecycle() {
        let log = CallLog()
        let ids = [10, 20, 30]

        let combined: Bracket<TestError, [Int]> = ids.traverse { id in
            makeBracket("id\(id)", log: log, resource: id)
        }
        let result = combined { resources in
            Result<[Int], TestError>.success(resources)
        }

        #expect(result == .success([10, 20, 30]))
    }

    @Test("traverse overload resolves without explicit type annotation")
    func traverseInfersBracketOverload() {
        let log = CallLog()
        let combined = [1, 2, 3].traverse { id in
            makeBracket("x\(id)", log: log, resource: id)
        }
        let result = combined { rs in Result<Int, TestError>.success(rs.reduce(0, +)) }
        #expect(result == .success(6))
    }

    @Test("map + sequence is equivalent to traverse")
    func mapThenSequenceEquivalent() {
        let log1 = CallLog()
        let log2 = CallLog()
        let ids = [1, 2, 3]

        let viaTraverse: Bracket<TestError, [Int]> = ids.traverse { id in
            makeBracket("t\(id)", log: log1, resource: id)
        }
        let viaMapSequence =
            ids
            .map { id in makeBracket("t\(id)", log: log2, resource: id) }
            .sequence()

        let r1 = viaTraverse { rs in Result<[Int], TestError>.success(rs) }
        let r2 = viaMapSequence { rs in Result<[Int], TestError>.success(rs) }

        #expect(r1 == r2)
        #expect(log1.events == log2.events)
    }

    // MARK: - async sequence

    @Test("async sequence: acquires left-to-right, releases right-to-left")
    func asyncSequenceLifecycle() async {
        let log = AsyncLog()
        let combined = [
            makeAsyncBracket("a", log: log, resource: 1),
            makeAsyncBracket("b", log: log, resource: 2),
            makeAsyncBracket("c", log: log, resource: 3),
        ].sequence()

        let result = await combined { resources in
            await log.record("use(\(resources))")
            return Result<Int, TestError>.success(resources.reduce(0, +))
        }

        #expect(result == .success(6))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "acquire(b)", "acquire(c)",
                "use([1, 2, 3])",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("async traverse maps elements to brackets and sequences them")
    func asyncTraverseLifecycle() async {
        let log = AsyncLog()
        let ids = [10, 20, 30]

        let combined: BracketAsync<TestError, [Int]> = ids.traverse { id in
            makeAsyncBracket("id\(id)", log: log, resource: id)
        }
        let result = await combined { resources in
            Result<[Int], TestError>.success(resources)
        }

        #expect(result == .success([10, 20, 30]))
    }
}
