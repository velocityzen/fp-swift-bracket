import HegelTesting
import Synchronization

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
// compare the logs and the outcomes.

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
enum LeafKind: Hashable, Sendable, CaseIterable {
    /// `init(acquire:dispose:)`.
    case plain
    /// `init(acquire:uncancellableDispose:)`.
    case uncancellable
    /// `throwing(acquire:dispose:)`, with `mapError` back to `Code`.
    case throwing
}

/// A bracket expression. The resource is an `Int`; a leaf's is its `id` plus
/// the offset its enclosing `flatMap` passes in, so an inner bracket depends
/// on the outer resource.
indirect enum Expr: Hashable, Sendable, CustomStringConvertible {
    case leaf(id: Int, acquire: Outcome, dispose: Outcome, kind: LeafKind)
    case of(Int)
    /// `fromAcquire`, or on the async side with `viaTask`, `fromTask`.
    case fromAcquire(id: Int, Outcome, viaTask: Bool)
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
            case .fromAcquire(let id, let a, let viaTask):
                return "\(viaTask ? "fromTask" : "fromAcquire")(\(id), \(a))"
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
}

/// Folds resources into one `Int`, for `sequence` and do-notation.
func combined(_ values: [Int]) -> Int {
    values.reduce(17) { $0 &* 31 &+ $1 }
}

func pair(_ a: Int, _ b: Int) -> Int { a &* 31 &+ b }

// MARK: - The model

final class ModelLog {
    var entries: [String] = []
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
        case .leaf(let id, let acquire, let dispose, _):
            log.entries.append("acquire \(id)")
            guard case .success(let value) = acquire.value(id &+ offset) else {
                return acquire.void
            }
            body(value)
            log.entries.append("dispose \(id) \(value)")
            return dispose.void
        case .of(let x):
            body(x)
            return .success(())
        case .fromAcquire(let id, let acquire, _):
            log.entries.append("acquire \(id)")
            guard case .success(let value) = acquire.value(id &+ offset) else {
                return acquire.void
            }
            body(value)
            return .success(())
        case .map(let e, let k):
            return run(e, offset: offset, log: log) { body($0 &+ k) }
        case .mapError(let e, let k):
            return run(e, offset: offset, log: log, body).mapError { Code(code: $0.code &+ k) }
        case .flatMap(let outer, let inner):
            return nested(outer, offset: offset, log: log) { o, innerBody in
                run(inner, offset: o, log: log) { innerBody(o, $0) }
            } combine: { _, i in
                i
            } body: {
                body($0)
            }
        case .tap(let outer, let inner):
            return nested(outer, offset: offset, log: log) { o, innerBody in
                run(inner, offset: o, log: log) { innerBody(o, $0) }
            } combine: { o, _ in
                o
            } body: {
                body($0)
            }
        case .bind(let outer, let inner):
            return nested(outer, offset: offset, log: log) { o, innerBody in
                run(inner, offset: o, log: log) { innerBody(o, $0) }
            } combine: { o, i in
                pair(o, i)
            } body: {
                body($0)
            }
        case .sequence(let es, _):
            return chain(es[...], [], offset: offset, log: log, body)
        case .constant(let e, let k):
            return run(e, offset: offset, log: log) { _ in body(k) }
        case .unit(let e):
            return run(e, offset: offset, log: log) { _ in body(0) }
    }
}

/// `outer.flatMap(inner)`: the inner bracket's failure wins over the outer
/// release's.
func nested(
    _ outer: Expr,
    offset: Int,
    log: ModelLog,
    inner: @escaping (Int, @escaping (Int, Int) -> Void) -> Result<Void, Code>,
    combine: @escaping (Int, Int) -> Int,
    body: @escaping (Int) -> Void
) -> Result<Void, Code> {
    var innerOutcome: Result<Void, Code> = .success(())
    let outerOutcome = run(outer, offset: offset, log: log) { o in
        innerOutcome = inner(o) { o, i in body(combine(o, i)) }
    }
    if case .failure = innerOutcome { return innerOutcome }
    return outerOutcome
}

/// `sequence()` as the `flatMap` chain its documentation says it matches.
func chain(
    _ rest: ArraySlice<Expr>,
    _ values: [Int],
    offset: Int,
    log: ModelLog,
    _ body: @escaping (Int) -> Void
) -> Result<Void, Code> {
    guard let first = rest.first else {
        body(combined(values))
        return .success(())
    }
    var innerOutcome: Result<Void, Code> = .success(())
    let outerOutcome = run(first, offset: offset, log: log) { value in
        innerOutcome = chain(rest.dropFirst(), values + [value], offset: offset, log: log, body)
    }
    if case .failure = innerOutcome { return innerOutcome }
    return outerOutcome
}

/// What a call gives: the scope's failure, or else the body's result.
func modelCall(
    _ e: Expr,
    body bodyResult: Result<Int, Code>,
    log: ModelLog
) -> Result<Int, Code> {
    let scope = run(e, offset: 0, log: log) { value in log.entries.append("body \(value)") }
    if case .failure(let error) = scope { return .failure(error) }
    return bodyResult
}

// MARK: - Generators

enum BracketGen {
    /// Small values usually, so outcomes and logs are easy to read; any `Int`
    /// sometimes, so the arithmetic wraps.
    static let value: Gen<Int> = .oneOf(.int(in: 0...9), .int(), .element(of: [.max, .min]))

    /// Mostly successes, so expressions run deep before something fails.
    static let outcome: Gen<Outcome> = .oneOf(
        .just(.ok),
        .just(.ok),
        .just(.ok),
        value.map { Outcome.fail($0) }
    )

    /// Releases fail half the time, so precedence between release failures
    /// is tested often.
    static let release: Gen<Outcome> = .oneOf(.just(.ok), value.map { Outcome.fail($0) })

    static let leaf: Gen<Expr> = .oneOf(
        Hegel.zip(.int(), outcome, release, .element(of: LeafKind.allCases)).map {
            Expr.leaf(id: $0, acquire: $1, dispose: $2, kind: $3)
        },
        value.map { Expr.of($0) },
        Hegel.zip(.int(), outcome, .bool()).map {
            Expr.fromAcquire(id: $0, $1, viaTask: $2)
        }
    )

    static let expr: Gen<Expr> = .recursive(leaf: leaf) { sub in
        Gen.oneOf(
            Hegel.zip(sub, value).map { Expr.map($0, $1) },
            Hegel.zip(sub, value).map { Expr.mapError($0, $1) },
            Hegel.zip(sub, sub).map { Expr.flatMap($0, $1) },
            Hegel.zip(sub, sub).map { Expr.tap($0, $1) },
            Hegel.zip(sub, sub).map { Expr.bind($0, $1) },
            Hegel.zip(.array(of: sub), .bool()).map {
                Expr.sequence($0, traverse: $1)
            },
            Hegel.zip(sub, value).map { Expr.constant($0, $1) },
            sub.map { Expr.unit($0) }
        )
    }

    static let body: Gen<Result<Int, Code>> = .oneOf(
        value.map { Result.success($0) },
        value.map { Result.failure(Code(code: $0)) }
    )
}

// MARK: - The real side's log

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

    init(onEntry: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onEntry = onEntry
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
