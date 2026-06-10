import FP

// This file mirrors Bracket+Do.swift — the overloads differ only in the
// BracketAsync vs Bracket type. When adding or changing an arity overload
// here, make the same change there.

// MARK: - Do Notation (Async)

/// Starting point for BracketAsync's do-notation chain.
///
/// Mirrors ``BracketDo`` for the async type. See ``BracketDo`` for an
/// overview of the do-notation tuple-accumulating style and the 10-element
/// flattening limit.
public struct BracketAsyncDo<E: Error> {
    public init() {}

    /// Binds the first BracketAsync in the chain.
    public func bind<A>(_ fn: () -> BracketAsync<A, E>) -> BracketAsync<A, E> {
        fn()
    }

    /// Adds a pure value as the first element in the chain.
    public func `let`<A>(_ fn: () -> A) -> BracketAsync<A, E> {
        .of(fn())
    }
}

// MARK: - bind / let (1 → 2)

public extension BracketAsync {
    /// Pairs this BracketAsync's resource with the next one's, starting a
    /// do-notation tuple. See ``BracketAsyncDo`` for the flattening limit.
    @_disfavoredOverload
    func bind<B>(
        _ fn: @escaping (R) -> BracketAsync<B, E>
    ) -> BracketAsync<(R, B), E> {
        flatMap { a in fn(a).map { b in (a, b) } }
    }

    /// Pairs this BracketAsync's resource with a pure value, starting a
    /// do-notation tuple. See ``BracketAsyncDo`` for the flattening limit.
    @_disfavoredOverload
    func `let`<B>(
        _ fn: @escaping (R) -> B
    ) -> BracketAsync<(R, B), E> {
        map { a in (a, fn(a)) }
    }
}

// MARK: - bind / let (2 → 3)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 3 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C>(
        _ fn: @escaping (A, B) -> BracketAsync<C, E>
    ) -> BracketAsync<(A, B, C), E> where R == (A, B) {
        flatMap { a, b in fn(a, b).map { c in (a, b, c) } }
    }

    /// Appends a pure value, widening the accumulated tuple to 3 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C>(
        _ fn: @escaping (A, B) -> C
    ) -> BracketAsync<(A, B, C), E> where R == (A, B) {
        map { a, b in (a, b, fn(a, b)) }
    }
}

// MARK: - bind / let (3 → 4)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 4 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> BracketAsync<D, E>
    ) -> BracketAsync<(A, B, C, D), E> where R == (A, B, C) {
        flatMap { a, b, c in fn(a, b, c).map { d in (a, b, c, d) } }
    }

    /// Appends a pure value, widening the accumulated tuple to 4 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> D
    ) -> BracketAsync<(A, B, C, D), E> where R == (A, B, C) {
        map { a, b, c in (a, b, c, fn(a, b, c)) }
    }
}

// MARK: - bind / let (4 → 5)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 5 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> BracketAsync<F, E>
    ) -> BracketAsync<(A, B, C, D, F), E> where R == (A, B, C, D) {
        flatMap { a, b, c, d in fn(a, b, c, d).map { f in (a, b, c, d, f) } }
    }

    /// Appends a pure value, widening the accumulated tuple to 5 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> F
    ) -> BracketAsync<(A, B, C, D, F), E> where R == (A, B, C, D) {
        map { a, b, c, d in (a, b, c, d, fn(a, b, c, d)) }
    }
}

// MARK: - bind / let (5 → 6)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 6 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> BracketAsync<G, E>
    ) -> BracketAsync<(A, B, C, D, F, G), E> where R == (A, B, C, D, F) {
        flatMap { a, b, c, d, f in fn(a, b, c, d, f).map { g in (a, b, c, d, f, g) } }
    }

    /// Appends a pure value, widening the accumulated tuple to 6 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> G
    ) -> BracketAsync<(A, B, C, D, F, G), E> where R == (A, B, C, D, F) {
        map { a, b, c, d, f in (a, b, c, d, f, fn(a, b, c, d, f)) }
    }
}

// MARK: - bind / let (6 → 7)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 7 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> BracketAsync<H, E>
    ) -> BracketAsync<(A, B, C, D, F, G, H), E> where R == (A, B, C, D, F, G) {
        flatMap { a, b, c, d, f, g in
            fn(a, b, c, d, f, g).map { h in (a, b, c, d, f, g, h) }
        }
    }

    /// Appends a pure value, widening the accumulated tuple to 7 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> H
    ) -> BracketAsync<(A, B, C, D, F, G, H), E> where R == (A, B, C, D, F, G) {
        map { a, b, c, d, f, g in (a, b, c, d, f, g, fn(a, b, c, d, f, g)) }
    }
}

// MARK: - bind / let (7 → 8)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 8 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> BracketAsync<I, E>
    ) -> BracketAsync<(A, B, C, D, F, G, H, I), E>
    where R == (A, B, C, D, F, G, H) {
        flatMap { a, b, c, d, f, g, h in
            fn(a, b, c, d, f, g, h).map { i in (a, b, c, d, f, g, h, i) }
        }
    }

    /// Appends a pure value, widening the accumulated tuple to 8 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> I
    ) -> BracketAsync<(A, B, C, D, F, G, H, I), E>
    where R == (A, B, C, D, F, G, H) {
        map { a, b, c, d, f, g, h in
            (a, b, c, d, f, g, h, fn(a, b, c, d, f, g, h))
        }
    }
}

// MARK: - bind / let (8 → 9)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 9 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func bind<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> BracketAsync<J, E>
    ) -> BracketAsync<(A, B, C, D, F, G, H, I, J), E>
    where R == (A, B, C, D, F, G, H, I) {
        flatMap { a, b, c, d, f, g, h, i in
            fn(a, b, c, d, f, g, h, i).map { j in (a, b, c, d, f, g, h, i, j) }
        }
    }

    /// Appends a pure value, widening the accumulated tuple to 9 elements.
    /// See ``BracketAsyncDo`` for the do-notation overview and flattening limit.
    func `let`<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> J
    ) -> BracketAsync<(A, B, C, D, F, G, H, I, J), E>
    where R == (A, B, C, D, F, G, H, I) {
        map { a, b, c, d, f, g, h, i in
            (a, b, c, d, f, g, h, i, fn(a, b, c, d, f, g, h, i))
        }
    }
}

// MARK: - bind / let (9 → 10)

public extension BracketAsync {
    /// Chains the next BracketAsync, widening the accumulated tuple to 10 elements
    /// — the last flattening arity. Past this point the chain still compiles but
    /// nests instead of flattening; see ``BracketAsyncDo``.
    func bind<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> BracketAsync<K, E>
    ) -> BracketAsync<(A, B, C, D, F, G, H, I, J, K), E>
    where R == (A, B, C, D, F, G, H, I, J) {
        flatMap { a, b, c, d, f, g, h, i, j in
            fn(a, b, c, d, f, g, h, i, j).map { k in (a, b, c, d, f, g, h, i, j, k) }
        }
    }

    /// Appends a pure value, widening the accumulated tuple to 10 elements
    /// — the last flattening arity. Past this point the chain still compiles but
    /// nests instead of flattening; see ``BracketAsyncDo``.
    func `let`<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> K
    ) -> BracketAsync<(A, B, C, D, F, G, H, I, J, K), E>
    where R == (A, B, C, D, F, G, H, I, J) {
        map { a, b, c, d, f, g, h, i, j in
            (a, b, c, d, f, g, h, i, j, fn(a, b, c, d, f, g, h, i, j))
        }
    }
}
