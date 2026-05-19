import FP

/// A scoped resource: the value itself plus the action that releases it.
///
/// Module-internal — extensions in other files (e.g. `Bracket+Sequence.swift`)
/// build `Bracket` values directly via ``Bracket/init(acquireResource:)``.
struct Resource<E: Error, R> {
    let value: R
    let release: () -> Result<Void, E>
}

/// `Bracket<E, R>` packages an acquire/dispose pair into a reusable, monadic
/// value that scopes work over a resource `R`.
///
/// Define `acquire` and `dispose` once, then call the bracket as a function
/// as many times as needed — each call acquires a fresh resource, runs the
/// callback, and releases.
///
/// ```swift
/// let withFile: Bracket<MyError, File> = Bracket(
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
public struct Bracket<E: Error, R> {
    // Module-internal: extensions reach in to build new Brackets from a raw
    // scope thunk (see `Bracket+Sequence.swift`). Not part of the public API.
    let acquireResource: () -> Result<Resource<E, R>, E>

    init(acquireResource: @escaping () -> Result<Resource<E, R>, E>) {
        self.acquireResource = acquireResource
    }

    /// Builds a Bracket from an acquire/dispose pair.
    public init(
        acquire: @escaping () -> Result<R, E>,
        dispose: @escaping (R) -> Result<Void, E>
    ) {
        self.acquireResource = {
            acquire().map { value in
                Resource(value: value, release: { dispose(value) })
            }
        }
    }

    /// A pure Bracket that yields `value` with a no-op acquire/dispose.
    public static func of(_ value: R) -> Bracket<E, R> {
        Bracket(acquireResource: {
            .success(Resource(value: value, release: { .success(()) }))
        })
    }

    /// Runs `body` with the acquired resource, releasing it afterwards.
    ///
    /// Invoked via call syntax: `bracket { resource in ... }`.
    ///
    /// - If `acquire` fails, `body` is not invoked and the failure is returned.
    /// - If `dispose` fails, its error wins over `body`'s outcome.
    public func callAsFunction<T>(_ body: (R) -> Result<T, E>) -> Result<T, E> {
        acquireResource().flatMap { resource in
            let bodyResult = body(resource.value)
            return resource.release().flatMap { _ in bodyResult }
        }
    }

    /// Transforms the resource view without changing the underlying acquire/dispose.
    public func map<S>(_ transform: @escaping (R) -> S) -> Bracket<E, S> {
        let acquire = acquireResource
        return Bracket<E, S>(acquireResource: {
            acquire().map { outer in
                Resource(value: transform(outer.value), release: outer.release)
            }
        })
    }

    /// Chains a second Bracket whose acquire depends on this Bracket's resource.
    ///
    /// The combined Bracket owns **both** resources: acquire runs outer then inner;
    /// release runs inner then outer. If inner's acquire fails, outer is released
    /// before the failure is returned.
    public func flatMap<S>(_ next: @escaping (R) -> Bracket<E, S>) -> Bracket<E, S> {
        let acquire = acquireResource
        return Bracket<E, S>(acquireResource: {
            acquire().flatMap { outer in
                next(outer.value).acquireResource()
                    .tapError { _ in _ = outer.release() }
                    .map { inner in
                        Resource(value: inner.value) {
                            let innerResult = inner.release()
                            let outerResult = outer.release()
                            return innerResult.flatMap { _ in outerResult }
                        }
                    }
            }
        })
    }

    /// Replaces the resource with a constant value.
    public func `as`<S>(_ value: S) -> Bracket<E, S> {
        map { _ in value }
    }

    /// Discards the resource value, yielding `Void`.
    public func asUnit() -> Bracket<E, Void> {
        map { _ in () }
    }
}
