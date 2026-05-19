import Testing
@testable import FPBracket

private enum TestError: Error, Equatable { case fail }

private final class CallLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor AsyncLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

@Suite("Bracket.tap")
struct BracketTapTests {

    @Test("tap acquires the side-effect bracket, keeps the outer resource")
    func tapKeepsOuterResource() {
        let log = CallLog()
        let outer = Bracket<TestError, Int>(
            acquire: { log.record("acquire(outer)"); return .success(1) },
            dispose: { _ in log.record("dispose(outer)"); return .success(()) }
        )
        let side = Bracket<TestError, String>(
            acquire: { log.record("acquire(side)"); return .success("X") },
            dispose: { _ in log.record("dispose(side)"); return .success(()) }
        )

        let composed = outer.tap { _ in side }
        let result = composed { r in
            log.record("use(\(r))")
            return Result<Int, TestError>.success(r * 10)
        }

        #expect(result == .success(10))
        #expect(log.events == [
            "acquire(outer)",
            "acquire(side)",
            "use(1)",
            "dispose(side)",
            "dispose(outer)",
        ])
    }

    @Test("tap propagates side-effect failure")
    func tapPropagatesFailure() {
        let outer = Bracket<TestError, Int>.of(1)
        let failingSide = Bracket<TestError, Int>(
            acquire: { .failure(.fail) },
            dispose: { _ in .success(()) }
        )

        let composed = outer.tap { _ in failingSide }
        let result = composed { _ in Result<Int, TestError>.success(0) }
        #expect(result == .failure(.fail))
    }

    @Test("async tap acquires the side-effect bracket, keeps the outer resource")
    func asyncTap() async {
        let log = AsyncLog()
        let outer = BracketAsync<TestError, Int>(
            acquire: { await log.record("acquire(outer)"); return .success(1) },
            dispose: { _ in await log.record("dispose(outer)"); return .success(()) }
        )
        let side = BracketAsync<TestError, String>(
            acquire: { await log.record("acquire(side)"); return .success("X") },
            dispose: { _ in await log.record("dispose(side)"); return .success(()) }
        )

        let composed = outer.tap { _ in side }
        let result = await composed { r in
            await log.record("use(\(r))")
            return Result<Int, TestError>.success(r * 10)
        }

        #expect(result == .success(10))
        #expect(await log.snapshot() == [
            "acquire(outer)",
            "acquire(side)",
            "use(1)",
            "dispose(side)",
            "dispose(outer)",
        ])
    }
}
