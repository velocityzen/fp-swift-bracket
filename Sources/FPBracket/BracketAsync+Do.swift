import FP

// MARK: - Do Notation (Async)

/// Starting point for BracketAsync's do-notation chain.
///
/// Mirrors ``BracketDo`` for the async type. See ``BracketDo`` for an
/// overview of the do-notation tuple-accumulating style.
public struct BracketAsyncDo<E: Error> {
    public init() {}

    /// Binds the first BracketAsync in the chain.
    public func bind<A>(_ fn: () -> BracketAsync<E, A>) -> BracketAsync<E, A> {
        fn()
    }

    /// Adds a pure value as the first element in the chain.
    public func `let`<A>(_ fn: () -> A) -> BracketAsync<E, A> {
        .of(fn())
    }
}

// MARK: - bind / let (1 → 2)

public extension BracketAsync {
    @_disfavoredOverload
    func bind<B>(
        _ fn: @escaping (R) -> BracketAsync<E, B>
    ) -> BracketAsync<E, (R, B)> {
        flatMap { a in fn(a).map { b in (a, b) } }
    }

    @_disfavoredOverload
    func `let`<B>(
        _ fn: @escaping (R) -> B
    ) -> BracketAsync<E, (R, B)> {
        map { a in (a, fn(a)) }
    }
}

// MARK: - bind / let (2 → 3)

public extension BracketAsync {
    func bind<A, B, C>(
        _ fn: @escaping (A, B) -> BracketAsync<E, C>
    ) -> BracketAsync<E, (A, B, C)> where R == (A, B) {
        flatMap { a, b in fn(a, b).map { c in (a, b, c) } }
    }

    func `let`<A, B, C>(
        _ fn: @escaping (A, B) -> C
    ) -> BracketAsync<E, (A, B, C)> where R == (A, B) {
        map { a, b in (a, b, fn(a, b)) }
    }
}

// MARK: - bind / let (3 → 4)

public extension BracketAsync {
    func bind<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> BracketAsync<E, D>
    ) -> BracketAsync<E, (A, B, C, D)> where R == (A, B, C) {
        flatMap { a, b, c in fn(a, b, c).map { d in (a, b, c, d) } }
    }

    func `let`<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> D
    ) -> BracketAsync<E, (A, B, C, D)> where R == (A, B, C) {
        map { a, b, c in (a, b, c, fn(a, b, c)) }
    }
}

// MARK: - bind / let (4 → 5)

public extension BracketAsync {
    func bind<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> BracketAsync<E, F>
    ) -> BracketAsync<E, (A, B, C, D, F)> where R == (A, B, C, D) {
        flatMap { a, b, c, d in fn(a, b, c, d).map { f in (a, b, c, d, f) } }
    }

    func `let`<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> F
    ) -> BracketAsync<E, (A, B, C, D, F)> where R == (A, B, C, D) {
        map { a, b, c, d in (a, b, c, d, fn(a, b, c, d)) }
    }
}

// MARK: - bind / let (5 → 6)

public extension BracketAsync {
    func bind<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> BracketAsync<E, G>
    ) -> BracketAsync<E, (A, B, C, D, F, G)> where R == (A, B, C, D, F) {
        flatMap { a, b, c, d, f in fn(a, b, c, d, f).map { g in (a, b, c, d, f, g) } }
    }

    func `let`<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> G
    ) -> BracketAsync<E, (A, B, C, D, F, G)> where R == (A, B, C, D, F) {
        map { a, b, c, d, f in (a, b, c, d, f, fn(a, b, c, d, f)) }
    }
}

// MARK: - bind / let (6 → 7)

public extension BracketAsync {
    func bind<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> BracketAsync<E, H>
    ) -> BracketAsync<E, (A, B, C, D, F, G, H)> where R == (A, B, C, D, F, G) {
        flatMap { a, b, c, d, f, g in
            fn(a, b, c, d, f, g).map { h in (a, b, c, d, f, g, h) }
        }
    }

    func `let`<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> H
    ) -> BracketAsync<E, (A, B, C, D, F, G, H)> where R == (A, B, C, D, F, G) {
        map { a, b, c, d, f, g in (a, b, c, d, f, g, fn(a, b, c, d, f, g)) }
    }
}

// MARK: - bind / let (7 → 8)

public extension BracketAsync {
    func bind<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> BracketAsync<E, I>
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I)>
    where R == (A, B, C, D, F, G, H) {
        flatMap { a, b, c, d, f, g, h in
            fn(a, b, c, d, f, g, h).map { i in (a, b, c, d, f, g, h, i) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> I
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I)>
    where R == (A, B, C, D, F, G, H) {
        map { a, b, c, d, f, g, h in
            (a, b, c, d, f, g, h, fn(a, b, c, d, f, g, h))
        }
    }
}

// MARK: - bind / let (8 → 9)

public extension BracketAsync {
    func bind<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> BracketAsync<E, J>
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I, J)>
    where R == (A, B, C, D, F, G, H, I) {
        flatMap { a, b, c, d, f, g, h, i in
            fn(a, b, c, d, f, g, h, i).map { j in (a, b, c, d, f, g, h, i, j) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> J
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I, J)>
    where R == (A, B, C, D, F, G, H, I) {
        map { a, b, c, d, f, g, h, i in
            (a, b, c, d, f, g, h, i, fn(a, b, c, d, f, g, h, i))
        }
    }
}

// MARK: - bind / let (9 → 10)

public extension BracketAsync {
    func bind<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> BracketAsync<E, K>
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I, J, K)>
    where R == (A, B, C, D, F, G, H, I, J) {
        flatMap { a, b, c, d, f, g, h, i, j in
            fn(a, b, c, d, f, g, h, i, j).map { k in (a, b, c, d, f, g, h, i, j, k) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> K
    ) -> BracketAsync<E, (A, B, C, D, F, G, H, I, J, K)>
    where R == (A, B, C, D, F, G, H, I, J) {
        map { a, b, c, d, f, g, h, i, j in
            (a, b, c, d, f, g, h, i, j, fn(a, b, c, d, f, g, h, i, j))
        }
    }
}
