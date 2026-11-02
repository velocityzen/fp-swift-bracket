/// Async counterpart of ``Resource``: an acquired resource plus the action
/// that releases it. Only `Array.sequence()` needs it.
@usableFromInline
struct AsyncResource<R, E: Error> {
    @usableFromInline let value: R
    @usableFromInline let release: () async -> Result<Void, E>

    @inlinable
    init(value: R, release: @escaping () async -> Result<Void, E>) {
        self.value = value
        self.release = release
    }
}

/// Async counterpart of ``Bracket``. Acquire, dispose, and use callbacks are
/// all `async`. See ``Bracket`` for full semantics — they are identical save
/// for the asynchronous suspension points.
///
/// ```swift
/// let withConnection: BracketAsync<Connection, DBError> = BracketAsync(
///     acquire: { await pool.checkOut() },
///     dispose: { conn in await pool.release(conn) }
/// )
///
/// let rows = await withConnection { conn in
///     await conn.query("SELECT * FROM users")
/// }
/// ```
public struct BracketAsync<R, E: Error> {
    // Not part of the public API; see `Bracket.Storage`.
    @usableFromInline
    enum Storage {
        /// An acquire/dispose pair, which a call runs as given.
        case direct(
            acquire: () async -> Result<R, E>,
            dispose: (R) async -> Result<Void, E>
        )
        /// A bracket built from others; see `Bracket.Storage.composed`.
        case composed(
            scope: (_ body: (R) async -> Void) async -> Result<Void, E>,
            acquireResource: () async -> Result<AsyncResource<R, E>, E>
        )
    }

    @usableFromInline let storage: Storage

    @inlinable
    init(
        scope: @escaping (_ body: (R) async -> Void) async -> Result<Void, E>,
        acquireResource: @escaping () async -> Result<AsyncResource<R, E>, E>
    ) {
        storage = .composed(scope: scope, acquireResource: acquireResource)
    }

    /// Builds a BracketAsync from an async acquire/dispose pair.
    @inlinable
    public init(
        acquire: @escaping () async -> Result<R, E>,
        dispose: @escaping (R) async -> Result<Void, E>
    ) {
        storage = .direct(acquire: acquire, dispose: dispose)
    }

    /// Builds a BracketAsync whose dispose can't be cancelled.
    ///
    /// Same as ``init(acquire:dispose:)``, except `uncancellableDispose` runs in
    /// a fresh unstructured `Task`, which doesn't inherit the caller's
    /// cancellation. Cancellation-aware cleanup (network calls, `Task.sleep`)
    /// therefore completes even when the caller is cancelled. The bracket
    /// stays structured: it awaits the cleanup before returning.
    ///
    /// Use it for cleanup that must finish, such as rolling back a remote
    /// transaction or releasing a distributed lock. That work can't
    /// be cancelled, so give it its own timeout if it might hang. See
    /// <doc:Cancellation>.
    ///
    /// ```swift
    /// let withTransaction = BracketAsync<Transaction, DBError>(
    ///     acquire: { await db.begin() },
    ///     uncancellableDispose: { tx in await tx.rollbackIfOpen() }
    /// )
    /// ```
    @inlinable
    public init(
        acquire: @escaping () async -> Result<R, E>,
        uncancellableDispose: @escaping @Sendable (R) async -> Result<Void, E>
    ) where R: Sendable, E: Sendable {
        self.init(
            acquire: acquire,
            dispose: { value in
                await Task { await uncancellableDispose(value) }.value
            }
        )
    }

    /// A pure BracketAsync that yields `value` with a no-op acquire/dispose.
    @inlinable
    public static func of(_ value: R) -> BracketAsync<R, E> {
        BracketAsync(acquire: { .success(value) }, dispose: { _ in .success(()) })
    }

    /// A BracketAsync whose acquire can fail but owns no resource to clean up.
    ///
    /// Async counterpart of ``Bracket/fromAcquire(_:)``: the value is computed
    /// lazily on every call, the computation can fail, and `dispose` is a
    /// no-op.
    ///
    /// ```swift
    /// let withUser = BracketAsync<User, APIError>.fromAcquire { await fetchUser() }
    /// ```
    @inlinable
    public static func fromAcquire(
        _ acquire: @escaping () async -> Result<R, E>
    ) -> BracketAsync<R, E> {
        BracketAsync(acquire: acquire, dispose: { _ in .success(()) })
    }

    /// Acquires, runs `body` with the resource, and releases it. Returns the
    /// acquire failure, or else the release outcome.
    @inlinable
    func scope(_ body: (R) async -> Void) async -> Result<Void, E> {
        switch storage {
            case .direct(let acquire, let dispose):
                switch await acquire() {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let resource):
                        await body(resource)
                        return await dispose(resource)
                }
            case .composed(let scope, _):
                return await scope(body)
        }
    }

    /// Whether this is an acquire/dispose pair; see ``Bracket``'s.
    @inlinable
    var isDirect: Bool {
        if case .direct = storage { return true }
        return false
    }

    /// Runs the acquire of a bracket that `isDirect`.
    @inlinable
    func directAcquire() async -> Result<R, E> {
        guard case .direct(let acquire, _) = storage else {
            preconditionFailure("not an acquire/dispose pair")
        }
        return await acquire()
    }

    /// Runs the dispose of a bracket that `isDirect`.
    @inlinable
    func directDispose(_ resource: R) async -> Result<Void, E> {
        guard case .direct(_, let dispose) = storage else {
            preconditionFailure("not an acquire/dispose pair")
        }
        return await dispose(resource)
    }

    /// Acquires the resource and hands back its release, for
    /// `Array.sequence()`.
    @inlinable
    func acquireResource() async -> Result<AsyncResource<R, E>, E> {
        switch storage {
            case .direct(let acquire, let dispose):
                return await acquire().map { value in
                    AsyncResource(value: value, release: { await dispose(value) })
                }
            case .composed(_, let acquireResource):
                return await acquireResource()
        }
    }

    /// Runs `body` with the acquired resource, releasing it afterwards.
    ///
    /// Invoked via call syntax: `await bracket { resource in ... }`.
    ///
    /// ## Cancellation
    ///
    /// Cancellation is cooperative: if the calling task is cancelled, `body`
    /// decides how to react, and release still runs once `body` returns. That
    /// includes nested releases from ``flatMap(_:)`` and `Array.sequence()`.
    /// Release runs in the *cancelled* task, though, so a dispose that awaits
    /// cancellation-aware work (`Task.sleep`, `URLSession`, a
    /// `Task.checkCancellation()` call) fails right away. Brackets built with
    /// ``init(acquire:uncancellableDispose:)`` are the exception.
    ///
    /// See <doc:Cancellation> for patterns that handle this.
    @inlinable
    public func callAsFunction<T>(
        _ body: (R) async -> Result<T, E>
    ) async -> Result<T, E> {
        var result: Result<T, E>?
        if case .failure(let error) = await scope({ result = await body($0) }) {
            return .failure(error)
        }
        // A scope that succeeds has run its body.
        return result!
    }

    /// Transforms the resource view without changing the underlying acquire/dispose.
    @inlinable
    public func map<S>(_ transform: @escaping (R) -> S) -> BracketAsync<S, E> {
        BracketAsync<S, E>(
            scope: { body in await scope { await body(transform($0)) } },
            acquireResource: {
                await acquireResource().map { resource in
                    AsyncResource(value: transform(resource.value), release: resource.release)
                }
            }
        )
    }

    /// Transforms the error type of both acquire and dispose, leaving the
    /// resource and lifecycle untouched. Async counterpart of
    /// ``Bracket/mapError(_:)``.
    ///
    /// Use it to line up error types before composing brackets from
    /// different layers:
    ///
    /// ```swift
    /// let withListener: BracketAsync<Listener, ServerError> = server.listener
    /// let withStore: BracketAsync<Store, StoreError> = …
    ///
    /// let withHost = withListener
    ///     .mapError(HostError.server)
    ///     .flatMap { _ in withStore.mapError(HostError.store) }
    ///
    /// // Or widen to `any Error` to meet a ``throwing(acquire:dispose:)`` bracket:
    /// let erased = withListener.mapError { $0 as any Error }
    /// ```
    ///
    /// The body passed to the resulting bracket returns `Result<T, F>`, so
    /// body errors are already in the new type.
    @inlinable
    public func mapError<F: Error>(_ transform: @escaping (E) -> F) -> BracketAsync<R, F> {
        switch storage {
            case .direct(let acquire, let dispose):
                return BracketAsync<R, F>(
                    acquire: { await acquire().mapError(transform) },
                    dispose: { await dispose($0).mapError(transform) }
                )
            case .composed:
                return BracketAsync<R, F>(
                    scope: { body in await scope(body).mapError(transform) },
                    acquireResource: {
                        await acquireResource().mapError(transform).map { resource in
                            AsyncResource(value: resource.value) {
                                await resource.release().mapError(transform)
                            }
                        }
                    }
                )
        }
    }

    /// Chains a second BracketAsync whose acquire depends on this one's resource.
    ///
    /// Acquire order is outer-then-inner; release order is inner-then-outer.
    /// If inner's acquire fails, outer is released before the failure is returned.
    @inlinable
    public func flatMap<S>(
        _ next: @escaping (R) -> BracketAsync<S, E>
    ) -> BracketAsync<S, E> {
        flatMap(next, combine: { _, inner in inner })
    }

    /// ``flatMap(_:)`` yielding `combine(outer, inner)`, so `tap` and
    /// do-notation keep the outer resource without building a bracket on
    /// every call.
    @inlinable
    func flatMap<S, T>(
        _ next: @escaping (R) -> BracketAsync<S, E>,
        combine: @escaping (R, S) -> T
    ) -> BracketAsync<T, E> {
        BracketAsync<T, E>(
            scope: { body in
                // The inner bracket's acquire or release failure wins over
                // the outer release's.
                var innerOutcome: Result<Void, E> = .success(())
                let outerOutcome = await scope { outer in
                    innerOutcome = await next(outer).scope { inner in
                        await body(combine(outer, inner))
                    }
                }
                if case .failure = innerOutcome {
                    return innerOutcome
                }
                return outerOutcome
            },
            acquireResource: {
                switch await acquireResource() {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let outer):
                        switch await next(outer.value).acquireResource() {
                            case .failure(let error):
                                _ = await outer.release()
                                return .failure(error)
                            case .success(let inner):
                                return .success(
                                    AsyncResource(value: combine(outer.value, inner.value)) {
                                        let innerResult = await inner.release()
                                        let outerResult = await outer.release()
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
    public func `as`<S>(_ value: S) -> BracketAsync<S, E> {
        map { _ in value }
    }

    /// Discards the resource value, yielding `Void`.
    @inlinable
    public func asUnit() -> BracketAsync<Void, E> {
        map { _ in () }
    }
}
