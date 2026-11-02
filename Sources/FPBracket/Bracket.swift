/// An acquired resource: the value itself plus the action that releases it.
///
/// Only `Array.sequence()` needs it, to hold many resources at once without
/// nesting a scope per resource; a call runs a bracket's scope instead.
@usableFromInline
struct Resource<R, E: Error> {
    @usableFromInline let value: R
    @usableFromInline let release: () -> Result<Void, E>

    @inlinable
    init(value: R, release: @escaping () -> Result<Void, E>) {
        self.value = value
        self.release = release
    }
}

/// `Bracket<R, E>` packages an acquire/dispose pair into a reusable, monadic
/// value that scopes work over a resource `R`.
///
/// Define `acquire` and `dispose` once, then call the bracket as a function
/// as many times as needed — each call acquires a fresh resource, runs the
/// callback, and releases.
///
/// ```swift
/// let withFile: Bracket<File, MyError> = Bracket(
///     acquire: { openFile(path) },
///     dispose: { file in closeFile(file) }
/// )
///
/// let contents: Result<String, MyError> = withFile { file in
///     readContents(file)
/// }
/// let lineCount: Result<Int, MyError> = withFile { file in
///     countLines(file)
/// }
/// ```
///
/// **Semantics**
/// - If `acquire` fails, `dispose` is **not** called.
/// - Otherwise the body runs and then `dispose` runs unconditionally — even on body failure.
/// - A `dispose` failure wins over the body's outcome.
///
/// **Composition**
/// - ``map(_:)`` transforms the visible resource type without changing the
///   underlying acquire/dispose.
/// - ``flatMap(_:)`` nests a second Bracket inside the first. Acquire order is
///   outer-then-inner; release order is inner-then-outer.
public struct Bracket<R, E: Error> {
    // Not part of the public API. Everything is `@inlinable`, so a call site
    // specializes the bracket for its own types: a call then costs about
    // what the same acquire/use/release written by hand does, and allocates
    // nothing of its own.
    @usableFromInline
    enum Storage {
        /// An acquire/dispose pair, which a call runs as given.
        case direct(
            acquire: () -> Result<R, E>,
            dispose: (R) -> Result<Void, E>
        )
        /// A bracket built from others. `scope` acquires, runs its body with
        /// the resource and releases, returning the failure the bracket's
        /// semantics pick, so nested brackets keep their resources on the
        /// stack. `acquireResource` acquires and hands back the release,
        /// which allocates; only `Array.sequence()` uses it.
        case composed(
            scope: (_ body: (R) -> Void) -> Result<Void, E>,
            acquireResource: () -> Result<Resource<R, E>, E>
        )
    }

    @usableFromInline let storage: Storage

    @inlinable
    init(
        scope: @escaping (_ body: (R) -> Void) -> Result<Void, E>,
        acquireResource: @escaping () -> Result<Resource<R, E>, E>
    ) {
        storage = .composed(scope: scope, acquireResource: acquireResource)
    }

    /// Builds a Bracket from an acquire/dispose pair.
    @inlinable
    public init(
        acquire: @escaping () -> Result<R, E>,
        dispose: @escaping (R) -> Result<Void, E>
    ) {
        storage = .direct(acquire: acquire, dispose: dispose)
    }

    /// A pure Bracket that yields `value` with a no-op acquire/dispose.
    @inlinable
    public static func of(_ value: R) -> Bracket<R, E> {
        Bracket(acquire: { .success(value) }, dispose: { _ in .success(()) })
    }

    /// A Bracket whose acquire can fail but owns no resource to clean up.
    ///
    /// Unlike ``of(_:)``, the value is computed lazily on every call and the
    /// computation can fail. `dispose` is a no-op. Useful for fallible steps
    /// in a `flatMap` or do-notation chain — loading configuration, validating
    /// input — that don't need a release phase.
    ///
    /// ```swift
    /// let withConfig = Bracket<Config, ConfigError>.fromAcquire { loadConfig() }
    /// ```
    @inlinable
    public static func fromAcquire(
        _ acquire: @escaping () -> Result<R, E>
    ) -> Bracket<R, E> {
        Bracket(acquire: acquire, dispose: { _ in .success(()) })
    }

    /// Acquires, runs `body` with the resource, and releases it. Returns the
    /// acquire failure, or else the release outcome.
    @inlinable
    func scope(_ body: (R) -> Void) -> Result<Void, E> {
        switch storage {
            case .direct(let acquire, let dispose):
                switch acquire() {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let resource):
                        body(resource)
                        return dispose(resource)
                }
            case .composed(let scope, _):
                return scope(body)
        }
    }

    /// Whether this is an acquire/dispose pair, which `Array.sequence()` can
    /// run without wrapping each release in a closure.
    @inlinable
    var isDirect: Bool {
        if case .direct = storage { return true }
        return false
    }

    /// Runs the acquire of a bracket that `isDirect`.
    @inlinable
    func directAcquire() -> Result<R, E> {
        guard case .direct(let acquire, _) = storage else {
            preconditionFailure("not an acquire/dispose pair")
        }
        return acquire()
    }

    /// Runs the dispose of a bracket that `isDirect`.
    @inlinable
    func directDispose(_ resource: R) -> Result<Void, E> {
        guard case .direct(_, let dispose) = storage else {
            preconditionFailure("not an acquire/dispose pair")
        }
        return dispose(resource)
    }

    /// Acquires the resource and hands back its release, for
    /// `Array.sequence()`.
    @inlinable
    func acquireResource() -> Result<Resource<R, E>, E> {
        switch storage {
            case .direct(let acquire, let dispose):
                return acquire().map { value in
                    Resource(value: value, release: { dispose(value) })
                }
            case .composed(_, let acquireResource):
                return acquireResource()
        }
    }

    /// Runs `body` with the acquired resource, releasing it afterwards.
    ///
    /// Invoked via call syntax: `bracket { resource in ... }`.
    ///
    /// - If `acquire` fails, `body` is not invoked and the failure is returned.
    /// - If `dispose` fails, its error wins over `body`'s outcome.
    @inlinable
    public func callAsFunction<T>(_ body: (R) -> Result<T, E>) -> Result<T, E> {
        var result: Result<T, E>?
        if case .failure(let error) = scope({ result = body($0) }) {
            return .failure(error)
        }
        // A scope that succeeds has run its body.
        return result!
    }

    /// Transforms the resource view without changing the underlying acquire/dispose.
    @inlinable
    public func map<S>(_ transform: @escaping (R) -> S) -> Bracket<S, E> {
        Bracket<S, E>(
            scope: { body in scope { body(transform($0)) } },
            acquireResource: {
                acquireResource().map { resource in
                    Resource(value: transform(resource.value), release: resource.release)
                }
            }
        )
    }

    /// Transforms the error type of both acquire and dispose, leaving the
    /// resource and lifecycle untouched.
    ///
    /// Use it to line up error types before composing brackets from
    /// different layers with ``flatMap(_:)`` or do-notation:
    ///
    /// ```swift
    /// let withFile: Bracket<File, FileError> = …
    /// let withDB: Bracket<DB, DBError> = …
    ///
    /// let withBoth = withFile
    ///     .mapError(AppError.file)
    ///     .flatMap { _ in withDB.mapError(AppError.db) }
    /// ```
    ///
    /// The body passed to the resulting bracket returns `Result<T, F>`, so
    /// body errors are already in the new type.
    @inlinable
    public func mapError<F: Error>(_ transform: @escaping (E) -> F) -> Bracket<R, F> {
        switch storage {
            case .direct(let acquire, let dispose):
                return Bracket<R, F>(
                    acquire: { acquire().mapError(transform) },
                    dispose: { dispose($0).mapError(transform) }
                )
            case .composed:
                return Bracket<R, F>(
                    scope: { body in scope(body).mapError(transform) },
                    acquireResource: {
                        acquireResource().mapError(transform).map { resource in
                            Resource(value: resource.value) {
                                resource.release().mapError(transform)
                            }
                        }
                    }
                )
        }
    }

    /// Chains a second Bracket whose acquire depends on this Bracket's resource.
    ///
    /// The combined Bracket owns **both** resources: acquire runs outer then inner;
    /// release runs inner then outer. If inner's acquire fails, outer is released
    /// before the failure is returned.
    @inlinable
    public func flatMap<S>(_ next: @escaping (R) -> Bracket<S, E>) -> Bracket<S, E> {
        flatMap(next, combine: { _, inner in inner })
    }

    /// ``flatMap(_:)`` yielding `combine(outer, inner)`, so `tap` and
    /// do-notation keep the outer resource without building a bracket on
    /// every call.
    @inlinable
    func flatMap<S, T>(
        _ next: @escaping (R) -> Bracket<S, E>,
        combine: @escaping (R, S) -> T
    ) -> Bracket<T, E> {
        Bracket<T, E>(
            scope: { body in
                // The inner bracket's acquire or release failure wins over
                // the outer release's.
                var innerOutcome: Result<Void, E> = .success(())
                let outerOutcome = scope { outer in
                    innerOutcome = next(outer).scope { inner in body(combine(outer, inner)) }
                }
                if case .failure = innerOutcome {
                    return innerOutcome
                }
                return outerOutcome
            },
            acquireResource: {
                acquireResource().flatMap { outer in
                    switch next(outer.value).acquireResource() {
                        case .failure(let error):
                            _ = outer.release()
                            return .failure(error)
                        case .success(let inner):
                            return .success(
                                Resource(value: combine(outer.value, inner.value)) {
                                    let innerResult = inner.release()
                                    let outerResult = outer.release()
                                    return innerResult.flatMap { _ in outerResult }
                                }
                            )
                    }
                }
            }
        )
    }

    /// Replaces the resource with a constant value.
    @inlinable
    public func `as`<S>(_ value: S) -> Bracket<S, E> {
        map { _ in value }
    }

    /// Discards the resource value, yielding `Void`.
    @inlinable
    public func asUnit() -> Bracket<Void, E> {
        map { _ in () }
    }
}
