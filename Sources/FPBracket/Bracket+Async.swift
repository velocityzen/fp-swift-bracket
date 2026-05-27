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

    /// A pure BracketAsync that yields `value` with a no-op acquire/dispose.
    public static func of(_ value: R) -> BracketAsync<R, E> {
        BracketAsync(acquireResource: {
            .success(AsyncResource(value: value, release: { .success(()) }))
        })
    }

    /// Runs `body` with the acquired resource, releasing it afterwards.
    ///
    /// Invoked via call syntax: `await bracket { resource in ... }`.
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
