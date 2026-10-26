import Testing
@testable import FPBracket

private enum FileError: Error, Equatable {
    case openFailed
    case closeFailed
}

private enum DBError: Error, Equatable {
    case connectFailed
    case disconnectFailed
}

private enum AppError: Error, Equatable {
    case file(FileError)
    case db(DBError)
    case body
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

private func makeBracket<E: Error>(
    _ tag: String,
    log: CallLog,
    acquireError: E? = nil,
    disposeError: E? = nil
) -> Bracket<String, E> {
    Bracket(
        acquire: {
            log.record("acquire(\(tag))")
            return acquireError.map { .failure($0) } ?? .success(tag)
        },
        dispose: { r in
            log.record("dispose(\(r))")
            return disposeError.map { .failure($0) } ?? .success(())
        }
    )
}

private func makeAsyncBracket<E: Error>(
    _ tag: String,
    log: AsyncLog,
    acquireError: E? = nil,
    disposeError: E? = nil
) -> BracketAsync<String, E> {
    BracketAsync(
        acquire: {
            await log.record("acquire(\(tag))")
            return acquireError.map { .failure($0) } ?? .success(tag)
        },
        dispose: { r in
            await log.record("dispose(\(r))")
            return disposeError.map { .failure($0) } ?? .success(())
        }
    )
}

@Suite("Bracket.mapError (sync)")
struct BracketMapErrorTests {

    @Test("mapError keeps the resource and lifecycle; body works in the new error type")
    func preservesLifecycle() {
        let log = CallLog()
        let bracket = makeBracket("file", log: log, acquireError: FileError?.none)
            .mapError(AppError.file)

        let result = bracket { r in
            log.record("use(\(r))")
            return Result<String, AppError>.success(r)
        }

        #expect(result == .success("file"))
        #expect(log.events == ["acquire(file)", "use(file)", "dispose(file)"])
    }

    @Test("mapError transforms acquire failure; dispose is skipped")
    func mapsAcquireFailure() {
        let log = CallLog()
        let bracket = makeBracket("file", log: log, acquireError: FileError.openFailed)
            .mapError(AppError.file)

        let result = bracket { _ in Result<Int, AppError>.success(0) }

        #expect(result == .failure(.file(.openFailed)))
        #expect(log.events == ["acquire(file)"])
    }

    @Test("mapError transforms dispose failure, which still wins over body success")
    func mapsDisposeFailure() {
        let log = CallLog()
        let bracket = makeBracket("file", log: log, disposeError: FileError.closeFailed)
            .mapError(AppError.file)

        let result = bracket { _ in Result<Int, AppError>.success(1) }

        #expect(result == .failure(.file(.closeFailed)))
        #expect(log.events == ["acquire(file)", "dispose(file)"])
    }

    @Test("mapError doesn't touch body failures")
    func leavesBodyFailureAlone() {
        let log = CallLog()
        let bracket = makeBracket("file", log: log, acquireError: FileError?.none)
            .mapError { error -> AppError in
                log.record("transform")
                return .file(error)
            }

        let result = bracket { _ in Result<Int, AppError>.failure(.body) }

        #expect(result == .failure(.body))
        #expect(log.events == ["acquire(file)", "dispose(file)"])
    }

    @Test("mapError lets brackets with different error types compose via flatMap")
    func composesDifferentErrorTypes() {
        let log = CallLog()
        let withFile = makeBracket("file", log: log, acquireError: FileError?.none)
        let withDB = makeBracket("db", log: log, disposeError: DBError.disconnectFailed)

        let composed =
            withFile
            .mapError(AppError.file)
            .flatMap { _ in withDB.mapError(AppError.db) }
        let result = composed { r in Result<String, AppError>.success(r) }

        #expect(result == .failure(.db(.disconnectFailed)))
        #expect(
            log.events == [
                "acquire(file)",
                "acquire(db)",
                "dispose(db)",
                "dispose(file)",
            ]
        )
    }
}

@Suite("BracketAsync.mapError")
struct BracketAsyncMapErrorTests {

    @Test("mapError keeps the resource and lifecycle; body works in the new error type")
    func preservesLifecycle() async {
        let log = AsyncLog()
        let bracket = makeAsyncBracket("file", log: log, acquireError: FileError?.none)
            .mapError(AppError.file)

        let result = await bracket { r in
            await log.record("use(\(r))")
            return Result<String, AppError>.success(r)
        }

        #expect(result == .success("file"))
        #expect(await log.snapshot() == ["acquire(file)", "use(file)", "dispose(file)"])
    }

    @Test("mapError transforms acquire failure; dispose is skipped")
    func mapsAcquireFailure() async {
        let log = AsyncLog()
        let bracket = makeAsyncBracket("file", log: log, acquireError: FileError.openFailed)
            .mapError(AppError.file)

        let result = await bracket { _ in Result<Int, AppError>.success(0) }

        #expect(result == .failure(.file(.openFailed)))
        #expect(await log.snapshot() == ["acquire(file)"])
    }

    @Test("mapError transforms dispose failure, which still wins over body success")
    func mapsDisposeFailure() async {
        let log = AsyncLog()
        let bracket = makeAsyncBracket("file", log: log, disposeError: FileError.closeFailed)
            .mapError(AppError.file)

        let result = await bracket { _ in Result<Int, AppError>.success(1) }

        #expect(result == .failure(.file(.closeFailed)))
        #expect(await log.snapshot() == ["acquire(file)", "dispose(file)"])
    }

    @Test("mapError lets brackets with different error types compose via flatMap")
    func composesDifferentErrorTypes() async {
        let log = AsyncLog()
        let withFile = makeAsyncBracket("file", log: log, acquireError: FileError?.none)
        let withDB = makeAsyncBracket("db", log: log, disposeError: DBError.disconnectFailed)

        let composed =
            withFile
            .mapError(AppError.file)
            .flatMap { _ in withDB.mapError(AppError.db) }
        let result = await composed { r in Result<String, AppError>.success(r) }

        #expect(result == .failure(.db(.disconnectFailed)))
        #expect(
            await log.snapshot() == [
                "acquire(file)",
                "acquire(db)",
                "dispose(db)",
                "dispose(file)",
            ]
        )
    }

    @Test("mapError widens to any Error to compose with a throwing bracket")
    func widensToAnyError() async {
        let log = AsyncLog()
        let withFile = makeAsyncBracket("file", log: log, acquireError: FileError.openFailed)
        let withSession = BracketAsync.throwing(
            acquire: { "session" },
            dispose: { _ in }
        )

        let composed = withSession.flatMap { _ in withFile.mapError { $0 as any Error } }
        let result = await composed { r in Result<String, any Error>.success(r) }

        switch result {
            case .success:
                Issue.record("expected failure")
            case .failure(let error):
                #expect(error as? FileError == .openFailed)
        }
        #expect(await log.snapshot() == ["acquire(file)"])
    }
}
