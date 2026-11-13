// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    // Random bracket expressions, built two ways: for real, from FPBracket, and as
    // a model that runs the documented semantics directly:
    //
    // - If acquire fails, dispose is not called.
    // - Otherwise the body runs, then dispose runs, even when the body fails.
    // - A dispose failure wins over the body's outcome.
    // - `flatMap` acquires outer then inner and releases inner then outer; the
    //   inner bracket's failure wins over the outer release's.
    // - `Array.sequence()` behaves like the equivalent `flatMap` chain.
    //
    // Both sides log every acquire, dispose and body call, and the properties
    // compare the logs and the outcomes. The model also notes what each call
    // went through, for the properties' reach claims.

    struct Code: Error, Hashable, Sendable {
        let code: Int
    }

    /// How an acquire or a dispose ends.
    enum Outcome: Hashable, Sendable, CustomStringConvertible {
        case ok
        case fail(Int)

        func value(_ value: Int) -> Result<Int, Code> {
            switch self {
                case .ok: .success(value)
                case .fail(let code): .failure(Code(code: code))
            }
        }

        var void: Result<Void, Code> {
            switch self {
                case .ok: .success(())
                case .fail(let code): .failure(Code(code: code))
            }
        }

        var description: String {
            switch self {
                case .ok: "ok"
                case .fail(let code): "fail(\(code))"
            }
        }
    }

    /// How the async side builds a leaf. The sync side builds each the plain way.
    enum LeafKind: String, Hashable, Sendable, CaseIterable {
        /// `init(acquire:dispose:)`.
        case plain
        /// `init(acquire:uncancellableDispose:)`.
        case uncancellable
        /// `throwing(acquire:dispose:)`, with `mapError` back to `Code`.
        case throwing

        /// The async bracket's constructor, for event labels.
        var label: String {
            switch self {
                case .plain: "init(acquire:dispose:)"
                case .uncancellable: "init(acquire:uncancellableDispose:)"
                case .throwing: "throwing(acquire:dispose:)"
            }
        }
    }

    /// How the async side builds a bracket that releases nothing. The sync
    /// side builds each with `fromAcquire`.
    enum FromKind: String, Hashable, Sendable, CaseIterable {
        /// `fromAcquire`.
        case acquire
        /// `fromTask` with a `Task<Result<R, E>, Never>`.
        case task
        /// `fromTask` with a `Task<R, any Error>`, mapped back to `Code`.
        case throwingTask
        /// `fromTask` with a `Task<R, Never>`, mapped from `Never` to `Code`.
        /// It can't fail.
        case neverTask

        /// The kinds that can fail.
        static let failing: [FromKind] = [.acquire, .task, .throwingTask]

        /// The async bracket's constructor, for event labels.
        var label: String {
            switch self {
                case .acquire: "fromAcquire"
                case .task: "fromTask (Result)"
                case .throwingTask: "fromTask (throws)"
                case .neverTask: "fromTask (Never)"
            }
        }
    }

    /// A bracket expression. The resource is an `Int`; a leaf's is its `id` plus
    /// the offset its enclosing `flatMap` passes in, so an inner bracket depends
    /// on the outer resource.
    indirect enum Expr: Hashable, Sendable, CustomStringConvertible {
        case leaf(id: Int, acquire: Outcome, dispose: Outcome, kind: LeafKind)
        case of(Int)
        /// `fromAcquire`, or on the async side one of the `fromTask` overloads.
        case fromAcquire(id: Int, Outcome, via: FromKind)
        /// Async only: an acquire that runs until the caller is cancelled,
        /// for checking that cancellation reaches it. Then it fails with
        /// `Code(id)`, except through `neverTask`, which gives its resource.
        case hang(id: Int, via: FromKind)
        case map(Expr, Int)
        case mapError(Expr, Int)
        case flatMap(Expr, Expr)
        case tap(Expr, Expr)
        /// Do-notation's pair `bind`, mapped to one `Int`.
        case bind(Expr, Expr)
        /// `sequence()`, or `traverse`, mapped to one `Int`.
        case sequence([Expr], traverse: Bool)
        case constant(Expr, Int)
        case unit(Expr)

        var description: String {
            switch self {
                case .leaf(let id, let a, let d, let kind):
                    return
                        "leaf(\(id), acquire: \(a), dispose: \(d)\(kind == .plain ? "" : ", \(kind)"))"
                case .of(let x): return "of(\(x))"
                case .fromAcquire(let id, let a, let via):
                    return "from(\(id), \(a)\(via == .acquire ? "" : ", \(via)"))"
                case .hang(let id, let via): return "hang(\(id), \(via))"
                case .map(let e, let k): return "\(e).map(+\(k))"
                case .mapError(let e, let k): return "\(e).mapError(+\(k))"
                case .flatMap(let o, let i): return "\(o).flatMap { \(i) }"
                case .tap(let o, let i): return "\(o).tap { \(i) }"
                case .bind(let o, let i): return "\(o).bind { \(i) }"
                case .sequence(let es, let traverse):
                    return "\(es).\(traverse ? "traverse" : "sequence")()"
                case .constant(let e, let k): return "\(e).as(\(k))"
                case .unit(let e): return "\(e).asUnit()"
            }
        }

        /// Whether the real bracket is an acquire/dispose pair, which
        /// `sequence()` runs on its own path. `mapError` keeps a pair a pair.
        var isDirect: Bool {
            switch self {
                case .leaf, .of, .fromAcquire, .hang: true
                case .mapError(let e, _): e.isDirect
                default: false
            }
        }
    }

    /// Folds resources into one `Int`, for `sequence` and do-notation.
    func combined(_ values: [Int]) -> Int {
        values.reduce(17) { $0 &* 31 &+ $1 }
    }

    func pair(_ a: Int, _ b: Int) -> Int { a &* 31 &+ b }

    /// What a `hang` gives once it is cancelled.
    func hangOutcome(id: Int, via: FromKind) -> Outcome {
        via == .neverTask ? .ok : .fail(id)
    }

    // MARK: - The model

    final class ModelLog {
        var entries: [String] = []
        /// What the call went through, as event labels.
        var reached: Set<String> = []
        /// What the async brackets' constructors went through, as event
        /// labels. The sync side builds every leaf the same way.
        var constructors: Set<String> = []
        /// How many acquires succeeded.
        var acquired = 0
        /// Resources acquired and not yet released.
        var held = 0
        var releaseFailures = 0
        var bodyRan = false
        /// How many hangs ran.
        var hangs = 0
        /// The first hang: the index of its entry, and how it was built.
        var firstHang: (entry: Int, via: FromKind)?

        func acquireFailed() {
            if held > 0 {
                reached.insert(Reach.rollback)
            }
        }
    }

    /// Runs `e` the way the documented semantics say: acquires, calls `body`
    /// with the resource, releases, and returns the failure that wins.
    func run(
        _ e: Expr,
        offset: Int,
        log: ModelLog,
        _ body: @escaping (Int) -> Void
    ) -> Result<Void, Code> {
        switch e {
            case .leaf, .fromAcquire, .hang:
                return runLeaf(e, offset: offset, log: log, body)
            case .of(let x):
                body(x)
                return .success(())
            case .map, .constant, .unit:
                return runMapped(e, offset: offset, log: log, body)
            case .mapError(let e, let k):
                return run(e, offset: offset, log: log, body).mapError { Code(code: $0.code &+ k) }
            case .flatMap(let outer, let inner):
                return nested(outer, inner, offset: offset, log: log) { _, i in body(i) }
            case .tap(let outer, let inner):
                return nested(outer, inner, offset: offset, log: log) { o, _ in body(o) }
            case .bind(let outer, let inner):
                return nested(outer, inner, offset: offset, log: log) { o, i in body(pair(o, i)) }
            case .sequence(let es, _):
                return runSequence(es, offset: offset, log: log, body)
        }
    }

    /// A leaf: an acquire/dispose pair, or a bracket that releases nothing.
    /// A failed acquire gives its failure, and nothing is released.
    func runLeaf(
        _ e: Expr,
        offset: Int,
        log: ModelLog,
        _ body: (Int) -> Void
    ) -> Result<Void, Code> {
        switch e {
            case .leaf(let id, let acquire, let dispose, let kind):
                log.entries.append("acquire \(id)")
                guard case .success(let value) = acquire.value(id &+ offset) else {
                    log.acquireFailed()
                    log.constructors.insert("\(kind.label): acquire failed")
                    return acquire.void
                }
                log.acquired += 1
                log.held += 1
                body(value)
                log.entries.append("dispose \(id) \(value)")
                log.held -= 1
                if case .fail = dispose {
                    log.releaseFailures += 1
                    log.constructors.insert("\(kind.label): release failed")
                }
                return dispose.void
            case .fromAcquire(let id, let acquire, let via):
                log.entries.append("acquire \(id)")
                guard case .success(let value) = acquire.value(id &+ offset) else {
                    log.acquireFailed()
                    log.constructors.insert("\(via.label): failed")
                    return acquire.void
                }
                log.acquired += 1
                log.constructors.insert("\(via.label): succeeded")
                body(value)
                return .success(())
            case .hang(let id, let via):
                log.hangs += 1
                if log.firstHang == nil {
                    log.firstHang = (log.entries.count, via)
                }
                let outcome = hangOutcome(id: id, via: via)
                return runLeaf(
                    .fromAcquire(id: id, outcome, via: via),
                    offset: offset,
                    log: log,
                    body
                )
            default:
                preconditionFailure("not a leaf: \(e)")
        }
    }

    /// `map`, `as` and `asUnit`: the same acquires and releases, with the
    /// resource the body gets transformed.
    func runMapped(
        _ e: Expr,
        offset: Int,
        log: ModelLog,
        _ body: @escaping (Int) -> Void
    ) -> Result<Void, Code> {
        switch e {
            case .map(let e, let k):
                run(e, offset: offset, log: log) { body($0 &+ k) }
            case .constant(let e, let k):
                run(e, offset: offset, log: log) { _ in body(k) }
            case .unit(let e):
                run(e, offset: offset, log: log) { _ in body(0) }
            default:
                preconditionFailure("not a resource transform: \(e)")
        }
    }

    /// The failure that wins when an inner bracket ran inside an outer one:
    /// the inner one's, over the outer release's.
    func winner(
        inner: Result<Void, Code>,
        outer: Result<Void, Code>,
        log: ModelLog
    ) -> Result<Void, Code> {
        guard case .failure = inner else { return outer }
        if case .failure = outer {
            log.reached.insert(Reach.innerBeatOuter)
        }
        return inner
    }

    /// `outer.flatMap(inner)`: the inner bracket's failure wins over the outer
    /// release's. `body` gets both resources.
    func nested(
        _ outer: Expr,
        _ inner: Expr,
        offset: Int,
        log: ModelLog,
        _ body: @escaping (Int, Int) -> Void
    ) -> Result<Void, Code> {
        var innerOutcome: Result<Void, Code> = .success(())
        let outerOutcome = run(outer, offset: offset, log: log) { o in
            innerOutcome = run(inner, offset: o, log: log) { body(o, $0) }
        }
        return winner(inner: innerOutcome, outer: outerOutcome, log: log)
    }

    /// `sequence()` as the `flatMap` chain its documentation says it matches,
    /// noting which of the real `sequence()`'s paths a rollback or release
    /// failures happened on: all acquire/dispose pairs, or not.
    func runSequence(
        _ es: [Expr],
        offset: Int,
        log: ModelLog,
        _ body: @escaping (Int) -> Void
    ) -> Result<Void, Code> {
        let direct = es.allSatisfy(\.isDirect)
        let releaseFailures = log.releaseFailures
        // The body runs inside the chain, and its releases aren't the
        // sequence's.
        var bodyReleaseFailures = 0

        func chain(_ rest: ArraySlice<Expr>, _ values: [Int]) -> Result<Void, Code> {
            guard let first = rest.first else {
                let start = log.releaseFailures
                body(combined(values))
                bodyReleaseFailures += log.releaseFailures - start
                return .success(())
            }
            var acquired = false
            var innerOutcome: Result<Void, Code> = .success(())
            let outerOutcome = run(first, offset: offset, log: log) { value in
                acquired = true
                innerOutcome = chain(rest.dropFirst(), values + [value])
            }
            if !acquired, !values.isEmpty {
                // This bracket failed to acquire after others had.
                log.reached.insert(direct ? Reach.directRollback : Reach.resourceRollback)
            }
            return winner(inner: innerOutcome, outer: outerOutcome, log: log)
        }

        let outcome = chain(es[...], [])
        if log.releaseFailures - releaseFailures - bodyReleaseFailures >= 2 {
            log.reached.insert(direct ? Reach.directReleasesFailed : Reach.resourceReleasesFailed)
        }
        return outcome
    }

    /// What a call gives: the scope's failure, or else the body's result.
    func modelCall(
        _ e: Expr,
        body bodyResult: Result<Int, Code>,
        log: ModelLog
    ) -> Result<Int, Code> {
        modelCall(body: bodyResult, log: log) { body in run(e, offset: 0, log: log, body) }
    }

    /// What a call of the bracket `scope` runs gives.
    func modelCall(
        body bodyResult: Result<Int, Code>,
        log: ModelLog,
        _ scope: (_ body: @escaping (Int) -> Void) -> Result<Void, Code>
    ) -> Result<Int, Code> {
        let outcome = scope { value in
            log.bodyRan = true
            log.entries.append("body \(value)")
        }
        guard case .failure(let error) = outcome else { return bodyResult }
        if log.bodyRan {
            // Everything was acquired, so a release failed.
            switch bodyResult {
                case .success: log.reached.insert(Reach.releaseBeatSucceedingBody)
                case .failure: log.reached.insert(Reach.releaseBeatFailingBody)
            }
        }
        return .failure(error)
    }

#endif
