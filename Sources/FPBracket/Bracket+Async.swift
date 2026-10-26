import FP

/// Async-flavoured scoped resource.
///
/// Module-internal — extensions in other files (e.g. `Bracket+Sequence.swift`)
/// build `BracketAsync` values directly via ``BracketAsync/init(acquireResource:)``.
struct AsyncResource<R, E: Error> {
    let value: R
    let release: () async -> Result<Void, E>
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
    // Module-internal: extensions reach in to build new Brackets from a raw
    // scope thunk (see `Bracket+Sequence.swift`). Not part of the public API.
    let acquireResource: () async -> Result<AsyncResource<R, E>, E>

    init(acquireResource: @escaping () async -> Result<AsyncResource<R, E>, E>) {
        self.acquireResource = acquireResource
    }

    /// Builds a BracketAsync from an async acquire/dispose pair.
    public init(
        acquire: @escaping () async -> Result<R, E>,
        dispose: @escaping (R) async -> Result<Void, E>
    ) {
        self.acquireResource = {
            await acquire().mapAsync { value in
                AsyncResource(value: value, release: { await dispose(value) })
            }
        }
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
    public static func of(_ value: R) -> BracketAsync<R, E> {
        BracketAsync(acquireResource: {
            .success(AsyncResource(value: value, release: { .success(()) }))
        })
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
    public static func fromAcquire(
        _ acquire: @escaping () async -> Result<R, E>
    ) -> BracketAsync<R, E> {
        BracketAsync(acquire: acquire, dispose: { _ in .success(()) })
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
    public func callAsFunction<T>(
        _ body: (R) async -> Result<T, E>
    ) async -> Result<T, E> {
        await acquireResource().flatMapAsync { resource in
            let bodyResult = await body(resource.value)
            return await resource.release().flatMap { _ in bodyResult }
        }
    }

    /// Transforms the resource view without changing the underlying acquire/dispose.
    public func map<S>(_ transform: @escaping (R) -> S) -> BracketAsync<S, E> {
        let acquire = acquireResource
        return BracketAsync<S, E>(acquireResource: {
            await acquire().map { outer in
                AsyncResource(value: transform(outer.value), release: outer.release)
            }
        })
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
    public func mapError<F: Error>(_ transform: @escaping (E) -> F) -> BracketAsync<R, F> {
        let acquire = acquireResource
        return BracketAsync<R, F>(acquireResource: {
            await acquire().mapError(transform).map { resource in
                AsyncResource(value: resource.value) {
                    await resource.release().mapError(transform)
                }
            }
        })
    }

    /// Chains a second BracketAsync whose acquire depends on this one's resource.
    ///
    /// Acquire order is outer-then-inner; release order is inner-then-outer.
    /// If inner's acquire fails, outer is released before the failure is returned.
    public func flatMap<S>(
        _ next: @escaping (R) -> BracketAsync<S, E>
    ) -> BracketAsync<S, E> {
        let acquire = acquireResource
        return BracketAsync<S, E>(acquireResource: {
            await acquire().flatMapAsync { outer in
                await next(outer.value).acquireResource()
                    .tapErrorAsync { _ in _ = await outer.release() }
                    .map { inner in
                        AsyncResource(value: inner.value) {
                            let innerResult = await inner.release()
                            let outerResult = await outer.release()
                            return innerResult.flatMap { _ in outerResult }
                        }
                    }
            }
        })
    }

    /// Replaces the resource with a constant value.
    public func `as`<S>(_ value: S) -> BracketAsync<S, E> {
        map { _ in value }
    }

    /// Discards the resource value, yielding `Void`.
    public func asUnit() -> BracketAsync<Void, E> {
        map { _ in () }
    }
}
