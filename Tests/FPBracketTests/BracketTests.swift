import Testing
@testable import FPBracket

private enum TestError: Error, Equatable {
    case acquireFailed
    case useFailed
    case disposeFailed
    case innerAcquireFailed
}

private final class CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private func makeBracket(
    _ tag: String,
    log: CallLog,
    resource: Int
) -> Bracket<TestError, Int> {
    Bracket(
        acquire: { log.record("acquire(\(tag))"); return .success(resource) },
        dispose: { r in log.record("dispose(\(tag), \(r))"); return .success(()) }
    )
}

@Suite("Bracket (sync)")
struct BracketTests {

    // MARK: - call semantics

    @Test("calling the bracket returns body's success and runs dispose")
    func happyPath() {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 42)
        let result = bracket { r in
            log.record("use(\(r))")
            return Result<Int, TestError>.success(r + 1)
        }

        #expect(result == .success(43))
        #expect(log.events == ["acquire(a)", "use(42)", "dispose(a, 42)"])
    }

    @Test("acquire failure short-circuits and skips dispose")
    func acquireFails() {
        let log = CallLog()
        let bracket = Bracket<TestError, Int>(
            acquire: { log.record("acquire"); return .failure(.acquireFailed) },
            dispose: { _ in log.record("dispose"); return .success(()) }
        )

        let result = bracket { (_: Int) -> Result<Int, TestError> in
            log.record("use")
            return .success(0)
        }

        #expect(result == .failure(.acquireFailed))
        #expect(log.events == ["acquire"])
    }

    @Test("dispose runs even when body fails; body's error is returned")
    func useFailsDisposeRuns() {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 7)
        let result = bracket { _ in
            log.record("use")
            return Result<Int, TestError>.failure(.useFailed)
        }

        #expect(result == .failure(.useFailed))
        #expect(log.events == ["acquire(a)", "use", "dispose(a, 7)"])
    }

    @Test("dispose failure wins over body success")
    func disposeOverridesUseSuccess() {
        let bracket = Bracket<TestError, Int>(
            acquire: { .success(1) },
            dispose: { _ in .failure(.disposeFailed) }
        )

        let result = bracket { _ in Result<Int, TestError>.success(99) }
        #expect(result == .failure(.disposeFailed))
    }

    @Test("dispose failure wins over body failure")
    func disposeOverridesUseFailure() {
        let bracket = Bracket<TestError, Int>(
            acquire: { .success(1) },
            dispose: { _ in .failure(.disposeFailed) }
        )

        let result = bracket { _ in Result<Int, TestError>.failure(.useFailed) }
        #expect(result == .failure(.disposeFailed))
    }

    // MARK: - Reusability

    @Test("the same Bracket can be invoked repeatedly with different bodies")
    func reuse() {
        let log = CallLog()
        let bracket = makeBracket("a", log: log, resource: 10)

        let r1 = bracket { r in Result<Int, TestError>.success(r * 2) }
        let r2 = bracket { r in Result<String, TestError>.success("v=\(r)") }

        #expect(r1 == .success(20))
        #expect(r2 == .success("v=10"))
        #expect(log.events == [
            "acquire(a)", "dispose(a, 10)",
            "acquire(a)", "dispose(a, 10)",
        ])
    }

    // MARK: - of

    @Test("of yields the pure value with no acquire/dispose effect")
    func ofPure() {
        let log = CallLog()
        let bracket = Bracket<TestError, Int>.of(42)
        let result = bracket { r in
            log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(42))
        #expect(log.events == ["use(42)"])
    }

    // MARK: - map

    @Test("map transforms the resource view, preserving acquire/dispose")
    func mapTransformsResource() {
        let log = CallLog()
        let mapped = makeBracket("a", log: log, resource: 5).map { $0 * 10 }

        let result = mapped { r in
            log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(50))
        #expect(log.events == ["acquire(a)", "use(50)", "dispose(a, 5)"])
    }

    // MARK: - flatMap

    @Test("flatMap nests two brackets; release order is inner-then-outer")
    func flatMapNestsScopes() {
        let log = CallLog()
        let outer = makeBracket("outer", log: log, resource: 1)
        let composed = outer.flatMap { _ in
            makeBracket("inner", log: log, resource: 2)
        }

        let result = composed { r in
            log.record("use(\(r))")
            return Result<Int, TestError>.success(r)
        }

        #expect(result == .success(2))
        #expect(log.events == [
            "acquire(outer)",
            "acquire(inner)",
            "use(2)",
            "dispose(inner, 2)",
            "dispose(outer, 1)",
        ])
    }

    @Test("flatMap releases outer when inner acquire fails")
    func flatMapReleasesOuterOnInnerAcquireFailure() {
        let log = CallLog()
        let outer = makeBracket("outer", log: log, resource: 1)
        let failingInner = Bracket<TestError, Int>(
            acquire: {
                log.record("acquire(inner)")
                return .failure(.innerAcquireFailed)
            },
            dispose: { r in log.record("dispose(inner, \(r))"); return .success(()) }
        )

        let composed = outer.flatMap { _ in failingInner }
        let result = composed { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.innerAcquireFailed))
        #expect(log.events == [
            "acquire(outer)",
            "acquire(inner)",
            "dispose(outer, 1)",
        ])
    }

    // MARK: - Monad laws

    @Test("left identity: of(a).flatMap(f) == f(a)")
    func leftIdentity() {
        let f: (Int) -> Bracket<TestError, String> = { n in .of("v=\(n)") }

        let lhsBracket = Bracket<TestError, Int>.of(7).flatMap(f)
        let lhs = lhsBracket { v in Result<String, TestError>.success(v) }

        let rhsBracket = f(7)
        let rhs = rhsBracket { v in Result<String, TestError>.success(v) }

        #expect(lhs == rhs)
    }

    @Test("right identity: m.flatMap(of) == m")
    func rightIdentity() {
        let logA = CallLog()
        let logB = CallLog()
        let m = makeBracket("a", log: logB, resource: 3)

        let lhsBracket = makeBracket("a", log: logA, resource: 3)
            .flatMap(Bracket<TestError, Int>.of)
        let lhs = lhsBracket { r in Result<Int, TestError>.success(r) }

        let rhs = m { r in Result<Int, TestError>.success(r) }

        #expect(lhs == rhs)
        #expect(logA.events == logB.events)
    }

    @Test("associativity: (m.flatMap(f)).flatMap(g) == m.flatMap { x in f(x).flatMap(g) }")
    func associativity() {
        let logA = CallLog()
        let logB = CallLog()
        let f: (CallLog) -> (Int) -> Bracket<TestError, Int> = { log in
            { n in makeBracket("f\(n)", log: log, resource: n + 1) }
        }
        let g: (CallLog) -> (Int) -> Bracket<TestError, Int> = { log in
            { n in makeBracket("g\(n)", log: log, resource: n * 10) }
        }

        let lhsBracket = makeBracket("base", log: logA, resource: 1)
            .flatMap(f(logA))
            .flatMap(g(logA))
        let lhs = lhsBracket { r in Result<Int, TestError>.success(r) }

        let rhsBracket = makeBracket("base", log: logB, resource: 1)
            .flatMap { x in f(logB)(x).flatMap(g(logB)) }
        let rhs = rhsBracket { r in Result<Int, TestError>.success(r) }

        #expect(lhs == rhs)
        #expect(logA.events == logB.events)
    }

    // MARK: - as / asUnit

    @Test("as replaces the resource with a constant")
    func asConstant() {
        let bracket = Bracket<TestError, Int>.of(7).as("hello")
        let result = bracket { v in Result<String, TestError>.success(v) }
        #expect(result == .success("hello"))
    }

    @Test("asUnit discards the resource")
    func asUnitDiscards() {
        let bracket = Bracket<TestError, Int>.of(7).asUnit()
        let result = bracket { _ in Result<Int, TestError>.success(1) }
        #expect(result == .success(1))
    }
}
