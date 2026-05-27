import FP

// MARK: - Do Notation

/// Starting point for Bracket's do-notation chain.
///
/// Provides `bind` and `let` to begin a monadic computation that accumulates
/// values into a growing tuple, short-circuiting on the first failure.
///
/// ```swift
/// let pipeline = BracketDo<MyError>()
///     .bind { withFile }                       // Bracket<File, MyError>
///     .bind { file in withDB(file) }           // Bracket<(File, DB), MyError>
///     .let { _, db in derivedKey(db) }         // Bracket<(File, DB, Key), MyError>
///     .map { file, _, key in (file, key) }     // Bracket<(File, Key), MyError>
/// ```
public struct BracketDo<E: Error> {
    public init() {}

    /// Binds the first Bracket in the chain.
    public func bind<A>(_ fn: () -> Bracket<A, E>) -> Bracket<A, E> {
        fn()
    }

    /// Adds a pure value as the first element in the chain.
    public func `let`<A>(_ fn: () -> A) -> Bracket<A, E> {
        .of(fn())
    }
}

// MARK: - bind / let (1 → 2)

public extension Bracket {
    @_disfavoredOverload
    func bind<B>(
        _ fn: @escaping (R) -> Bracket<B, E>
    ) -> Bracket<(R, B), E> {
        flatMap { a in fn(a).map { b in (a, b) } }
    }

    @_disfavoredOverload
    func `let`<B>(
        _ fn: @escaping (R) -> B
    ) -> Bracket<(R, B), E> {
        map { a in (a, fn(a)) }
    }
}

// MARK: - bind / let (2 → 3)

public extension Bracket {
    func bind<A, B, C>(
        _ fn: @escaping (A, B) -> Bracket<C, E>
    ) -> Bracket<(A, B, C), E> where R == (A, B) {
        flatMap { a, b in fn(a, b).map { c in (a, b, c) } }
    }

    func `let`<A, B, C>(
        _ fn: @escaping (A, B) -> C
    ) -> Bracket<(A, B, C), E> where R == (A, B) {
        map { a, b in (a, b, fn(a, b)) }
    }
}

// MARK: - bind / let (3 → 4)

public extension Bracket {
    func bind<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> Bracket<D, E>
    ) -> Bracket<(A, B, C, D), E> where R == (A, B, C) {
        flatMap { a, b, c in fn(a, b, c).map { d in (a, b, c, d) } }
    }

    func `let`<A, B, C, D>(
        _ fn: @escaping (A, B, C) -> D
    ) -> Bracket<(A, B, C, D), E> where R == (A, B, C) {
        map { a, b, c in (a, b, c, fn(a, b, c)) }
    }
}

// MARK: - bind / let (4 → 5)

public extension Bracket {
    func bind<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> Bracket<F, E>
    ) -> Bracket<(A, B, C, D, F), E> where R == (A, B, C, D) {
        flatMap { a, b, c, d in fn(a, b, c, d).map { f in (a, b, c, d, f) } }
    }

    func `let`<A, B, C, D, F>(
        _ fn: @escaping (A, B, C, D) -> F
    ) -> Bracket<(A, B, C, D, F), E> where R == (A, B, C, D) {
        map { a, b, c, d in (a, b, c, d, fn(a, b, c, d)) }
    }
}

// MARK: - bind / let (5 → 6)

public extension Bracket {
    func bind<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> Bracket<G, E>
    ) -> Bracket<(A, B, C, D, F, G), E> where R == (A, B, C, D, F) {
        flatMap { a, b, c, d, f in fn(a, b, c, d, f).map { g in (a, b, c, d, f, g) } }
    }

    func `let`<A, B, C, D, F, G>(
        _ fn: @escaping (A, B, C, D, F) -> G
    ) -> Bracket<(A, B, C, D, F, G), E> where R == (A, B, C, D, F) {
        map { a, b, c, d, f in (a, b, c, d, f, fn(a, b, c, d, f)) }
    }
}

// MARK: - bind / let (6 → 7)

public extension Bracket {
    func bind<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> Bracket<H, E>
    ) -> Bracket<(A, B, C, D, F, G, H), E> where R == (A, B, C, D, F, G) {
        flatMap { a, b, c, d, f, g in
            fn(a, b, c, d, f, g).map { h in (a, b, c, d, f, g, h) }
        }
    }

    func `let`<A, B, C, D, F, G, H>(
        _ fn: @escaping (A, B, C, D, F, G) -> H
    ) -> Bracket<(A, B, C, D, F, G, H), E> where R == (A, B, C, D, F, G) {
        map { a, b, c, d, f, g in (a, b, c, d, f, g, fn(a, b, c, d, f, g)) }
    }
}

// MARK: - bind / let (7 → 8)

public extension Bracket {
    func bind<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> Bracket<I, E>
    ) -> Bracket<(A, B, C, D, F, G, H, I), E> where R == (A, B, C, D, F, G, H) {
        flatMap { a, b, c, d, f, g, h in
            fn(a, b, c, d, f, g, h).map { i in (a, b, c, d, f, g, h, i) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I>(
        _ fn: @escaping (A, B, C, D, F, G, H) -> I
    ) -> Bracket<(A, B, C, D, F, G, H, I), E> where R == (A, B, C, D, F, G, H) {
        map { a, b, c, d, f, g, h in
            (a, b, c, d, f, g, h, fn(a, b, c, d, f, g, h))
        }
    }
}

// MARK: - bind / let (8 → 9)

public extension Bracket {
    func bind<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> Bracket<J, E>
    ) -> Bracket<(A, B, C, D, F, G, H, I, J), E>
    where R == (A, B, C, D, F, G, H, I) {
        flatMap { a, b, c, d, f, g, h, i in
            fn(a, b, c, d, f, g, h, i).map { j in (a, b, c, d, f, g, h, i, j) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I, J>(
        _ fn: @escaping (A, B, C, D, F, G, H, I) -> J
    ) -> Bracket<(A, B, C, D, F, G, H, I, J), E>
    where R == (A, B, C, D, F, G, H, I) {
        map { a, b, c, d, f, g, h, i in
            (a, b, c, d, f, g, h, i, fn(a, b, c, d, f, g, h, i))
        }
    }
}

// MARK: - bind / let (9 → 10)

public extension Bracket {
    func bind<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> Bracket<K, E>
    ) -> Bracket<(A, B, C, D, F, G, H, I, J, K), E>
    where R == (A, B, C, D, F, G, H, I, J) {
        flatMap { a, b, c, d, f, g, h, i, j in
            fn(a, b, c, d, f, g, h, i, j).map { k in (a, b, c, d, f, g, h, i, j, k) }
        }
    }

    func `let`<A, B, C, D, F, G, H, I, J, K>(
        _ fn: @escaping (A, B, C, D, F, G, H, I, J) -> K
    ) -> Bracket<(A, B, C, D, F, G, H, I, J, K), E>
    where R == (A, B, C, D, F, G, H, I, J) {
        map { a, b, c, d, f, g, h, i, j in
            (a, b, c, d, f, g, h, i, j, fn(a, b, c, d, f, g, h, i, j))
        }
    }
}
