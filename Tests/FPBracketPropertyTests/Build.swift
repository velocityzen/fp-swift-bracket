// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPBracket
    import HegelTesting
    import Synchronization
    import Testing

    // The real brackets for an `Expr`, logging what they do the way the model does.

    // MARK: - The log

    /// What the real brackets did, in order. Safe to use from any task.
    final class Log: Sendable {
        struct Dispose: Sendable {
            let event: Int
            let kind: LeafKind
            let sawCancellation: Bool
        }

        private let state = Mutex<(entries: [String], disposes: [Dispose])>(([], []))
        /// Called with each entry after it is added.
        let onEntry: @Sendable (String) -> Void
        /// What the `hang` leaves wait on.
        let probe = CancellationProbe()
        /// Whether the drawn cancel has landed, for the `hang` leaves.
        let cancelLanded: @Sendable () -> Bool

        init(
            onEntry: @escaping @Sendable (String) -> Void = { _ in },
            cancelLanded: @escaping @Sendable () -> Bool = { false }
        ) {
            self.onEntry = onEntry
            self.cancelLanded = cancelLanded
        }

        func add(_ entry: String) {
            state.withLock { $0.entries.append(entry) }
            onEntry(entry)
        }

        /// Logs a dispose, and whether the task running it was cancelled.
        func dispose(_ entry: String, kind: LeafKind) {
            let sawCancellation = Task.isCancelled
            state.withLock {
                $0.disposes.append(
                    Dispose(event: $0.entries.count, kind: kind, sawCancellation: sawCancellation)
                )
            }
            add(entry)
        }

        var entries: [String] { state.withLock { $0.entries } }
        var disposes: [Dispose] { state.withLock { $0.disposes } }
    }

    // MARK: - Bracket

    func bracket(_ e: Expr, offset: Int = 0, log: Log) -> Bracket<Int, Code> {
        switch e {
            case .leaf(let id, let acquire, let dispose, _):
                return Bracket(
                    acquire: {
                        log.add("acquire \(id)")
                        return acquire.value(id &+ offset)
                    },
                    dispose: { value in
                        log.dispose("dispose \(id) \(value)", kind: .plain)
                        return dispose.void
                    }
                )
            case .of(let x):
                return .of(x)
            case .fromAcquire(let id, let acquire, _):
                return .fromAcquire {
                    log.add("acquire \(id)")
                    return acquire.value(id &+ offset)
                }
            case .hang:
                preconditionFailure("a hang has no sync bracket: it waits for a cancellation")
            case .map(let e, let k):
                return bracket(e, offset: offset, log: log).map { $0 &+ k }
            case .mapError(let e, let k):
                return bracket(e, offset: offset, log: log).mapError { Code(code: $0.code &+ k) }
            case .flatMap(let outer, let inner):
                return bracket(outer, offset: offset, log: log).flatMap { o in
                    bracket(inner, offset: o, log: log)
                }
            case .tap(let outer, let inner):
                return bracket(outer, offset: offset, log: log).tap { o in
                    bracket(inner, offset: o, log: log)
                }
            case .bind(let outer, let inner):
                return bracket(outer, offset: offset, log: log)
                    .bind { o in bracket(inner, offset: o, log: log) }
                    .map { pair($0, $1) }
            case .sequence(let es, let traverse):
                let all: Bracket<[Int], Code> =
                    traverse
                    ? es.traverse { bracket($0, offset: offset, log: log) }
                    : es.map { bracket($0, offset: offset, log: log) }.sequence()
                return all.map(combined)
            case .constant(let e, let k):
                return bracket(e, offset: offset, log: log).as(k)
            case .unit(let e):
                return bracket(e, offset: offset, log: log).asUnit().map { 0 }
        }
    }

    /// Calls the bracket with a body that logs the resource and returns `result`.
    func call(_ b: Bracket<Int, Code>, body result: Result<Int, Code>, log: Log) -> Result<
        Int, Code
    > {
        b { value in
            log.add("body \(value)")
            return result
        }
    }

    // MARK: - BracketAsync

    func bracketAsync(_ e: Expr, offset: Int = 0, log: Log) -> BracketAsync<Int, Code> {
        switch e {
            case .leaf(let id, let acquire, let dispose, let kind):
                let leaf = AsyncLeaf(
                    id: id,
                    acquire: acquire,
                    dispose: dispose,
                    offset: offset,
                    log: log
                )
                return leaf.bracket(kind)
            case .of(let x):
                return .of(x)
            case .fromAcquire(let id, let acquire, let via):
                let leaf = AsyncLeaf(
                    id: id,
                    acquire: acquire,
                    dispose: .ok,
                    offset: offset,
                    log: log
                )
                return leaf.from(via)
            case .hang(let id, let via):
                let leaf = AsyncLeaf(
                    id: id,
                    acquire: hangOutcome(id: id, via: via),
                    dispose: .ok,
                    offset: offset,
                    log: log
                )
                return leaf.hang(via)
            case .map(let e, let k):
                return bracketAsync(e, offset: offset, log: log).map { $0 &+ k }
            case .mapError(let e, let k):
                return bracketAsync(e, offset: offset, log: log).mapError {
                    Code(code: $0.code &+ k)
                }
            case .flatMap(let outer, let inner):
                return bracketAsync(outer, offset: offset, log: log).flatMap { o in
                    bracketAsync(inner, offset: o, log: log)
                }
            case .tap(let outer, let inner):
                return bracketAsync(outer, offset: offset, log: log).tap { o in
                    bracketAsync(inner, offset: o, log: log)
                }
            case .bind(let outer, let inner):
                return bracketAsync(outer, offset: offset, log: log)
                    .bind { o in bracketAsync(inner, offset: o, log: log) }
                    .map { pair($0, $1) }
            case .sequence(let es, let traverse):
                let all: BracketAsync<[Int], Code> =
                    traverse
                    ? es.traverse { bracketAsync($0, offset: offset, log: log) }
                    : es.map { bracketAsync($0, offset: offset, log: log) }.sequence()
                return all.map(combined)
            case .constant(let e, let k):
                return bracketAsync(e, offset: offset, log: log).as(k)
            case .unit(let e):
                return bracketAsync(e, offset: offset, log: log).asUnit().map { 0 }
        }
    }

    /// An async leaf, or `fromAcquire`, built each way the async side can build
    /// it. Each suspends before it acquires and disposes.
    struct AsyncLeaf: Sendable {
        let id: Int
        let acquire: Outcome
        /// Unused by `fromAcquire`, which releases nothing.
        let dispose: Outcome
        let offset: Int
        let log: Log

        func acquireValue() async -> Result<Int, Code> {
            await Task.yield()
            log.add("acquire \(id)")
            return acquire.value(id &+ offset)
        }

        func bracket(_ kind: LeafKind) -> BracketAsync<Int, Code> {
            switch kind {
                case .plain:
                    return BracketAsync(
                        acquire: acquireValue,
                        dispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .plain)
                            return dispose.void
                        }
                    )
                case .uncancellable:
                    return BracketAsync(
                        acquire: acquireValue,
                        uncancellableDispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .uncancellable)
                            return dispose.void
                        }
                    )
                case .throwing:
                    return BracketAsync<Int, any Error>.throwing(
                        acquire: { try await acquireValue().get() },
                        dispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .throwing)
                            try dispose.void.get()
                        }
                    ).mapError(thrownCode)
            }
        }

        /// A bracket that releases nothing, built `via` the given
        /// constructor. A `fromTask` task logs its acquire at once, without
        /// suspending first.
        func from(_ via: FromKind) -> BracketAsync<Int, Code> {
            from(via) {}
        }

        /// A bracket like `from(via)` whose acquire, once it has logged,
        /// runs until its task is cancelled. Through `fromAcquire` that is
        /// the caller's task; through `fromTask` it is the task `fromTask`
        /// made, which only a forwarded cancellation reaches.
        func hang(_ via: FromKind) -> BracketAsync<Int, Code> {
            let probe = log.probe
            let cancelLanded = log.cancelLanded
            return from(via) {
                // The drawn cancel lands by the first hang's acquire entry,
                // which is logged before this. If it hasn't landed, it never
                // will, and there is nothing to wait for. If it has, wait for
                // it however long it takes: `endsWithin` reports a cancel
                // that never arrives.
                guard cancelLanded() else { return }
                await probe.hang()
            }
        }

        /// `from(via)`, running `wait` between logging the acquire and
        /// ending it.
        private func from(
            _ via: FromKind,
            wait: @escaping @Sendable () async -> Void
        ) -> BracketAsync<Int, Code> {
            let log = log
            let entry = "acquire \(id)"
            let outcome = acquire.value(id &+ offset)
            switch via {
                case .acquire:
                    return .fromAcquire {
                        await Task.yield()
                        log.add(entry)
                        await wait()
                        return outcome
                    }
                case .task:
                    return .fromTask {
                        Task {
                            log.add(entry)
                            await wait()
                            return outcome
                        }
                    }
                case .throwingTask:
                    return BracketAsync<Int, any Error>.fromTask {
                        Task {
                            log.add(entry)
                            await wait()
                            return try outcome.get()
                        }
                    }.mapError(thrownCode)
                case .neverTask:
                    // `mapError(thrownCode)` is never called. A closure
                    // taking `Never` would be unreachable code, which the
                    // compiler warns about.
                    return BracketAsync<Int, Never>.fromTask {
                        Task {
                            log.add(entry)
                            await wait()
                            // The generators give `neverTask` only successes.
                            return (try? outcome.get()) ?? 0
                        }
                    }.mapError(thrownCode)
            }
        }
    }

    /// The `Code` a throwing leaf threw: it throws nothing else.
    func thrownCode(_ error: any Error) -> Code {
        guard let code = error as? Code else {
            Issue.record("a throwing leaf threw \(error), not a Code")
            return Code(code: .min)
        }
        return code
    }

    /// Calls the async bracket with a body that logs the resource, suspends,
    /// and returns `result`.
    func call(
        _ b: BracketAsync<Int, Code>,
        body result: Result<Int, Code>,
        log: Log
    ) async -> Result<Int, Code> {
        await b { value in
            log.add("body \(value)")
            await Task.yield()
            return result
        }
    }

#endif
