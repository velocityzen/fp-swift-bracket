import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case acquireFailed
    case useFailed
    case disposeFailed
    case innerAcquireFailed
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

@Suite("BracketAsync")
struct BracketAsyncTests {

    // MARK: - call semantics

    @Test("calling the bracket returns body's success and runs dispose")
    func happyPath() async {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 42)
        let result = await bracket { r in
            await log.record("use(\(r))")
            return Result<Int, TestError>.success(r + 1)
        }

        #expect(result == .success(43))
        #expect(await log.snapshot() == ["acquire(a)", "use(42)", "dispose(a, 42)"])
    }

    @Test("acquire failure short-circuits and skips dispose")
    func acquireFails() async {
        let log = CallLog()
        let bracket = BracketAsync<Int, TestError>(
            acquire: {
                await log.record("acquire")
                return .failure(.acquireFailed)
            },
            dispose: { _ in
                await log.record("dispose"); return .success(())
            }
        )

        let result = await bracket { (_: Int) -> Result<Int, TestError> in
            await log.record("use")
            return .success(0)
        }

        #expect(result == .failure(.acquireFailed))
        #expect(await log.snapshot() == ["acquire"])
    }

    @Test("dispose runs even when body fails; body's error is returned")
    func useFailsDisposeRuns() async {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 7)
        let result = await bracket { _ in
            await log.record("use")
            return Result<Int, TestError>.failure(.useFailed)
        }

        #expect(result == .failure(.useFailed))
        #expect(await log.snapshot() == ["acquire(a)", "use", "dispose(a, 7)"])
    }

    @Test("dispose failure wins over body success")
    func disposeOverridesUseSuccess() async {
        let bracket = BracketAsync<Int, TestError>(
            acquire: { .success(1) },
            dispose: { _ in .failure(.disposeFailed) }
        )
        let result = await bracket { _ in Result<Int, TestError>.success(99) }
        #expect(result == .failure(.disposeFailed))
    }

    // MARK: - Reusability

    @Test("the same BracketAsync can be invoked repeatedly with different bodies")
    func reuse() async {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 10)

        let r1 = await bracket { r in Result<Int, TestError>.success(r * 2) }
        let r2 = await bracket { r in Result<String, TestError>.success("v=\(r)") }

        #expect(r1 == .success(20))
        #expect(r2 == .success("v=10"))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "dispose(a, 10)",
                "acquire(a)", "dispose(a, 10)",
            ]
        )
    }

    // MARK: - of

    @Test("of yields the pure value with no acquire/dispose effect")
    func ofPure() async {
        let log = CallLog()
        let bracket = BracketAsync<Int, TestError>.of(42)
        let result = await bracket { r in
            await log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(42))
        #expect(await log.snapshot() == ["use(42)"])
    }

    // MARK: - map

    @Test("map transforms the resource view, preserving acquire/dispose")
    func mapTransformsResource() async {
        let log = CallLog()
        let mapped = makeBracket("a", log: log, resource: 5).map { $0 * 10 }

        let result = await mapped { r in
            await log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(50))
        #expect(await log.snapshot() == ["acquire(a)", "use(50)", "dispose(a, 5)"])
    }

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

    // MARK: - Monad laws

    @Test("left identity: of(a).flatMap(f) == f(a)")
    func leftIdentity() async {
        let f: (Int) -> BracketAsync<String, TestError> = { n in .of("v=\(n)") }
        let lhsBracket = BracketAsync<Int, TestError>.of(7).flatMap(f)
        let lhs = await lhsBracket { v in Result<String, TestError>.success(v) }

        let rhsBracket = f(7)
        let rhs = await rhsBracket { v in Result<String, TestError>.success(v) }
        #expect(lhs == rhs)
    }

    @Test("right identity: m.flatMap(of) == m (same effect trace)")
    func rightIdentity() async {
        let logA = CallLog()
        let logB = CallLog()
        let mA = makeBracket("a", log: logA, resource: 3)
            .flatMap(BracketAsync<Int, TestError>.of)
        let mB = makeBracket("a", log: logB, resource: 3)

        let lhs = await mA { r in Result<Int, TestError>.success(r) }
        let rhs = await mB { r in Result<Int, TestError>.success(r) }

        #expect(lhs == rhs)
        #expect(await logA.snapshot() == (await logB.snapshot()))
    }
}
