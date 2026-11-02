import Testing
@testable import FPBracket

// `sequence()` runs an array of plain acquire/dispose brackets directly, and
// falls back to holding one release per bracket as soon as one of them is
// composed. These cover that fallback.

private enum TestError: Error, Equatable {
    case acquireFailed
    case disposeFailed(String)
}

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
    resource: Int,
    acquireFails: Bool = false,
    disposeFails: Bool = false
) -> Bracket<Int, TestError> {
    Bracket(
        acquire: {
            log.record("acquire(\(tag))")
            return acquireFails ? .failure(.acquireFailed) : .success(resource)
        },
        dispose: { _ in
            log.record("dispose(\(tag))")
            return disposeFails ? .failure(.disposeFailed(tag)) : .success(())
        }
    )
}

private func makeAsyncBracket(
    _ tag: String,
    log: AsyncLog,
    resource: Int,
    acquireFails: Bool = false,
    disposeFails: Bool = false
) -> BracketAsync<Int, TestError> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))")
            return acquireFails ? .failure(.acquireFailed) : .success(resource)
        },
        dispose: { _ in
            await log.record("dispose(\(tag))")
            return disposeFails ? .failure(.disposeFailed(tag)) : .success(())
        }
    )
}

@Suite("Array.sequence of composed brackets")
struct ArrayComposedSequenceTests {

    @Test("acquires left-to-right, releases right-to-left, nested releases included")
    func lifecycle() {
        let log = CallLog()
        let combined = [
            makeBracket("a", log: log, resource: 1),
            makeBracket("b", log: log, resource: 2).map { $0 * 10 },
            makeBracket("c", log: log, resource: 3)
                .flatMap { _ in makeBracket("d", log: log, resource: 4) },
        ].sequence()

        let result = combined { resources in
            log.record("use(\(resources))")
            return Result<Int, TestError>.success(resources.reduce(0, +))
        }

        #expect(result == .success(25))
        #expect(
            log.events == [
                "acquire(a)", "acquire(b)", "acquire(c)", "acquire(d)",
                "use([1, 20, 4])",
                "dispose(d)", "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("releases what was acquired when a later acquire fails")
    func releasesOnAcquireFailure() {
        let log = CallLog()
        let combined = [
            makeBracket("a", log: log, resource: 1),
            makeBracket("b", log: log, resource: 2).map { $0 * 10 },
            makeBracket("c", log: log, resource: 3)
                .flatMap { _ in makeBracket("d", log: log, resource: 4, acquireFails: true) },
            makeBracket("e", log: log, resource: 5),
        ].sequence()

        let result = combined { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.acquireFailed))
        #expect(
            log.events == [
                "acquire(a)", "acquire(b)", "acquire(c)", "acquire(d)",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("the most recent dispose error wins; remaining disposes still run")
    func disposeFailurePrecedence() {
        let log = CallLog()
        let combined = [
            makeBracket("a", log: log, resource: 1, disposeFails: true),
            makeBracket("b", log: log, resource: 2, disposeFails: true).map { $0 * 10 },
            makeBracket("c", log: log, resource: 3),
        ].sequence()

        let result = combined { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.disposeFailed("b")))
        #expect(
            log.events == [
                "acquire(a)", "acquire(b)", "acquire(c)",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    // Each bracket's resource is held at once, so a sequence that nested a
    // call per bracket would need stack in proportion to the count.
    @Test("runs in constant stack depth however many brackets it holds")
    func manyBrackets() {
        let count = 100_000
        let brackets = (0..<count).map { index in
            Bracket<Int, TestError>(acquire: { .success(index) }, dispose: { _ in .success(()) })
                .map { $0 + 1 }
        }

        let combined = brackets.sequence()

        let result = combined { resources in
            Result<Int, TestError>.success(resources.count)
        }

        #expect(result == .success(count))
    }

    // MARK: - async

    @Test("async: acquires left-to-right, releases right-to-left, nested releases included")
    func asyncLifecycle() async {
        let log = AsyncLog()
        let combined = [
            makeAsyncBracket("a", log: log, resource: 1),
            makeAsyncBracket("b", log: log, resource: 2).map { $0 * 10 },
            makeAsyncBracket("c", log: log, resource: 3)
                .flatMap { _ in makeAsyncBracket("d", log: log, resource: 4) },
        ].sequence()

        let result = await combined { resources in
            await log.record("use(\(resources))")
            return Result<Int, TestError>.success(resources.reduce(0, +))
        }

        #expect(result == .success(25))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "acquire(b)", "acquire(c)", "acquire(d)",
                "use([1, 20, 4])",
                "dispose(d)", "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("async: releases what was acquired when a later acquire fails")
    func asyncReleasesOnAcquireFailure() async {
        let log = AsyncLog()
        let combined = [
            makeAsyncBracket("a", log: log, resource: 1),
            makeAsyncBracket("b", log: log, resource: 2).map { $0 * 10 },
            makeAsyncBracket("c", log: log, resource: 3)
                .flatMap { _ in
                    makeAsyncBracket("d", log: log, resource: 4, acquireFails: true)
                },
            makeAsyncBracket("e", log: log, resource: 5),
        ].sequence()

        let result = await combined { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.acquireFailed))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "acquire(b)", "acquire(c)", "acquire(d)",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }

    @Test("async: the most recent dispose error wins; remaining disposes still run")
    func asyncDisposeFailurePrecedence() async {
        let log = AsyncLog()
        let combined = [
            makeAsyncBracket("a", log: log, resource: 1, disposeFails: true),
            makeAsyncBracket("b", log: log, resource: 2, disposeFails: true).map { $0 * 10 },
            makeAsyncBracket("c", log: log, resource: 3),
        ].sequence()

        let result = await combined { _ in Result<Int, TestError>.success(0) }

        #expect(result == .failure(.disposeFailed("b")))
        #expect(
            await log.snapshot() == [
                "acquire(a)", "acquire(b)", "acquire(c)",
                "dispose(c)", "dispose(b)", "dispose(a)",
            ]
        )
    }
}
