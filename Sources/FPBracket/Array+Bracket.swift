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
    /// ```swift
    /// let brackets: [Bracket<Connection, PoolError>] = configs.map(withConnection)
    /// let withAll: Bracket<[Connection], PoolError> = brackets.sequence()
    ///
    /// let report = withAll { connections in healthCheck(connections) }
    /// ```
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
    /// O(N²)` array copies on top of the O(N) acquire/release work. A chain
    /// of N scopes would also nest N calls deep on the stack.
    ///
    /// When every bracket is an acquire/dispose pair, the result is one too:
    /// a call acquires into a single array of values and disposes each value
    /// with its own bracket's `dispose`, allocating only that array. Otherwise
    /// each bracket hands back its release, which allocates one closure per
    /// bracket, and the releases run from a second array.
    @inlinable
    func sequence<R, E>() -> Bracket<[R], E> where Element == Bracket<R, E> {
        guard allSatisfy(\.isDirect) else {
            return sequenceResources()
        }
        let brackets = self

        return Bracket<[R], E>(
            acquire: {
                var values: [R] = []
                values.reserveCapacity(brackets.count)

                // Acquire left-to-right. On the first failure, dispose
                // everything already acquired, in reverse order, and
                // propagate the error.
                for bracket in brackets {
                    switch bracket.directAcquire() {
                        case .failure(let error):
                            for index in values.indices.reversed() {
                                _ = brackets[index].directDispose(values[index])
                            }
                            return .failure(error)
                        case .success(let value):
                            values.append(value)
                    }
                }
                return .success(values)
            },
            dispose: { values in
                // Dispose in reverse acquire order. Keep the first error
                // (the most recently acquired bracket's, matching the
                // flatMap-chain semantics); still run the remaining disposes
                // for cleanup.
                var firstError: E?
                for index in values.indices.reversed() {
                    if case .failure(let error) = brackets[index].directDispose(values[index]),
                        firstError == nil
                    {
                        firstError = error
                    }
                }
                return firstError.map { .failure($0) } ?? .success(())
            }
        )
    }

    /// Maps each element to a Bracket and sequences them.
    /// Equivalent to `map(transform).sequence()`.
    ///
    /// ```swift
    /// let withFiles: Bracket<[File], MyError> = paths
    ///     .traverse { path in withFile(path) }
    /// ```
    @inlinable
    func traverse<R, E>(
        _ transform: (Element) -> Bracket<R, E>
    ) -> Bracket<[R], E> {
        map(transform).sequence()
    }
}

extension Array {
    /// `sequence()` for brackets that aren't all acquire/dispose pairs.
    @inlinable
    func sequenceResources<R, E>() -> Bracket<[R], E> where Element == Bracket<R, E> {
        let brackets = self
        let acquireResource: () -> Result<Resource<[R], E>, E> = {
            var values: [R] = []
            values.reserveCapacity(brackets.count)

            var releases: [() -> Result<Void, E>] = []
            releases.reserveCapacity(brackets.count)

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
        }

        return Bracket<[R], E>(
            scope: { body in
                switch acquireResource() {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let resource):
                        body(resource.value)
                        return resource.release()
                }
            },
            acquireResource: acquireResource
        )
    }
}

// MARK: - Array.sequence() / .traverse(_:) for BracketAsync

public extension Array {
    /// Async variant of ``Swift/Array/sequence()->Bracket<[R],E>`` for BracketAsync.
    /// See that overload for the rationale behind the imperative implementation.
    @inlinable
    func sequence<R, E>() -> BracketAsync<[R], E>
    where Element == BracketAsync<R, E> {
        guard allSatisfy(\.isDirect) else {
            return sequenceResources()
        }
        let brackets = self

        return BracketAsync<[R], E>(
            acquire: {
                var values: [R] = []
                values.reserveCapacity(brackets.count)

                for bracket in brackets {
                    switch await bracket.directAcquire() {
                        case .failure(let error):
                            for index in values.indices.reversed() {
                                _ = await brackets[index].directDispose(values[index])
                            }
                            return .failure(error)
                        case .success(let value):
                            values.append(value)
                    }
                }
                return .success(values)
            },
            dispose: { values in
                var firstError: E?
                for index in values.indices.reversed() {
                    if case .failure(let error) = await brackets[index].directDispose(
                        values[index]
                    ),
                        firstError == nil
                    {
                        firstError = error
                    }
                }
                return firstError.map { .failure($0) } ?? .success(())
            }
        )
    }

    /// Async variant of ``Swift/Array/traverse(_:)->Bracket<[R],E>`` for BracketAsync.
    @inlinable
    func traverse<R, E>(
        _ transform: (Element) -> BracketAsync<R, E>
    ) -> BracketAsync<[R], E> {
        map(transform).sequence()
    }
}

extension Array {
    /// `sequence()` for async brackets that aren't all acquire/dispose pairs.
    @inlinable
    func sequenceResources<R, E>() -> BracketAsync<[R], E>
    where Element == BracketAsync<R, E> {
        let brackets = self
        let acquireResource: () async -> Result<AsyncResource<[R], E>, E> = {
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
        }

        return BracketAsync<[R], E>(
            scope: { body in
                switch await acquireResource() {
                    case .failure(let error):
                        return .failure(error)
                    case .success(let resource):
                        await body(resource.value)
                        return await resource.release()
                }
            },
            acquireResource: acquireResource
        )
    }
}
