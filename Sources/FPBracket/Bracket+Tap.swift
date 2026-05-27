import FP

public extension Bracket {
    /// Runs a side-effecting Bracket built from the current resource, discards
    /// its resource, and keeps the outer resource for the rest of the chain.
    ///
    /// Useful for composing additional scoped effects whose result is not
    /// needed downstream (logging, tracing, ancillary handles).
    ///
    /// ```swift
    /// let withFileAndLock = withFile.tap { file in withLock(file) }
    /// ```
    func tap<X>(_ action: @escaping (R) -> Bracket<X, E>) -> Bracket<R, E> {
        flatMap { resource in action(resource).map { _ in resource } }
    }
}

public extension BracketAsync {
    /// Async variant of ``Bracket/tap(_:)``.
    func tap<X>(
        _ action: @escaping (R) -> BracketAsync<X, E>
    ) -> BracketAsync<R, E> {
        flatMap { resource in action(resource).map { _ in resource } }
    }
}
