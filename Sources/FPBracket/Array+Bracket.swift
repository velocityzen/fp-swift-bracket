import FP

// MARK: - Array.sequence() / .traverse(_:) for Bracket

public extension Array {
    /// Combines an array of Brackets into a single Bracket that yields the
    /// array of acquired resources.
    ///
    /// Resources are acquired left-to-right and released right-to-left around
    /// the body. If any acquire fails, previously acquired resources are
    /// released and the failure is propagated.
    ///
    /// Release-failure precedence matches the equivalent `flatMap` chain: the
    /// most recently acquired bracket's release error wins; subsequent dispose
    /// actions still run for cleanup but their errors are dropped.
    ///
    /// ## Implementation note
    ///
    /// This is written as an imperative loop rather than a
    /// `reduce { acc.flatMap { rs in next.map { r in rs + [r] } } }` fold.
    ///
    /// The fold is the obvious, four-line functional form, but each step
    /// builds `rs + [r]` inside a captured closure: `rs` is captured by value,
    /// and `+ [r]` allocates a fresh array of length `k+1` and copies the
    /// previous `k` elements. Repeated N times that's `0 + 1 + … + (N-1) =
    /// O(N²)` array copies on top of the O(N) acquire/release work.
    ///
    /// The imperative form below threads two mutable arrays (`values`,
    /// `releases`) and is O(N) end-to-end at the cost of reaching into
    /// `Bracket`'s module-internal storage (``Resource`` and
    /// ``Bracket/init(acquireResource:)``). The trade-off is worth it because
    /// `sequence` is the one place we expect to handle larger N (think:
    /// opening dozens of connections in parallel-then-scoped patterns).
    func sequence<R, E>() -> Bracket<[R], E> where Element == Bracket<R, E> {
        let brackets = self
        return Bracket<[R], E>(acquireResource: {
            var values: [R] = []
            values.reserveCapacity(brackets.count)

            var releases: [() -> Result<Void, E>] = []
            releases.reserveCapacity(brackets.count)

            // Acquire left-to-right. On the first failure, release everything
            // already acquired (in reverse order) and propagate the error.
            for bracket in brackets {
                switch bracket.acquireResource() {
                    case .failure(let error):
                        for release in releases.reversed() {
                            _ = release()
                        }
                        return .failure(error)
                    case .success(let resource):
                        values.append(resource.value)
                        releases.append(resource.release)
                }
            }

            // Combined release: run every dispose in reverse acquire order.
            // Keep the first error encountered (= the most recently acquired
            // bracket's dispose error, matching the flatMap-chain semantics);
            // still run the remaining disposes for cleanup.
            let combinedRelease: () -> Result<Void, E> = {
                var firstError: E?
                for release in releases.reversed() {
                    if case .failure(let error) = release(), firstError == nil {
                        firstError = error
                    }
                }
                return firstError.map { .failure($0) } ?? .success(())
            }

            return .success(Resource(value: values, release: combinedRelease))
        })
    }

    /// Maps each element to a Bracket and sequences them.
    /// Equivalent to `map(transform).sequence()`.
    func traverse<R, E>(
        _ transform: (Element) -> Bracket<R, E>
    ) -> Bracket<[R], E> {
        map(transform).sequence()
    }
}

// MARK: - Array.sequence() / .traverse(_:) for BracketAsync

public extension Array {
    /// Async variant of ``Swift/Array/sequence()-(_)`` for BracketAsync.
    /// See that overload for the rationale behind the imperative implementation.
    func sequence<R, E>() -> BracketAsync<[R], E>
    where Element == BracketAsync<R, E> {
        let brackets = self
        return BracketAsync<[R], E>(acquireResource: {
            var values: [R] = []
            values.reserveCapacity(brackets.count)

            var releases: [() async -> Result<Void, E>] = []
            releases.reserveCapacity(brackets.count)

            for bracket in brackets {
                switch await bracket.acquireResource() {
                    case .failure(let error):
                        for release in releases.reversed() {
                            _ = await release()
                        }
                        return .failure(error)
                    case .success(let resource):
                        values.append(resource.value)
                        releases.append(resource.release)
                }
            }

            let combinedRelease: () async -> Result<Void, E> = {
                var firstError: E?
                for release in releases.reversed() {
                    if case .failure(let error) = await release(), firstError == nil {
                        firstError = error
                    }
                }
                return firstError.map { .failure($0) } ?? .success(())
            }

            return .success(AsyncResource(value: values, release: combinedRelease))
        })
    }

    /// Async variant of ``Swift/Array/traverse(_:)`` for BracketAsync.
    func traverse<R, E>(
        _ transform: (Element) -> BracketAsync<R, E>
    ) -> BracketAsync<[R], E> {
        map(transform).sequence()
    }
}
