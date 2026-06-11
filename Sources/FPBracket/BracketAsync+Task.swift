import FP

// MARK: - BracketAsync from Task

// All variants take a closure rather than a concrete `Task` on purpose:
// brackets are reusable recipes, so each call should run a fresh task. To
// scope one already-running task instead, capture it — `fromTask { shared }` —
// and every call awaits the same (memoized) value.

public extension BracketAsync {
    /// A BracketAsync that runs a fresh `Task` per call and yields its
    /// `Result`; `dispose` is a no-op.
    ///
    /// This is the typed-error variant: the task itself never fails, the
    /// `Result` it produces carries the bracket's error.
    ///
    /// ```swift
    /// let withUser = BracketAsync<User, APIError>.fromTask {
    ///     Task { await api.fetchUser() }  // Task<Result<User, APIError>, Never>
    /// }
    /// ```
    static func fromTask(
        _ makeTask: @escaping () -> Task<Result<R, E>, Never>
    ) -> BracketAsync<R, E> where R: Sendable, E: Sendable {
        fromAcquire { await makeTask().value }
    }
}

public extension BracketAsync where E == Error {
    /// A BracketAsync that runs a fresh throwing `Task` per call; a thrown
    /// error becomes the bracket's failure. `dispose` is a no-op.
    ///
    /// ```swift
    /// let withUser = BracketAsync<User, Error>.fromTask {
    ///     Task { try await api.fetchUser() }
    /// }
    /// ```
    static func fromTask(
        _ makeTask: @escaping () -> Task<R, Error>
    ) -> BracketAsync<R, Error> where R: Sendable {
        fromAcquire { await Result.fromTask(makeTask()) }
    }
}

public extension BracketAsync where E == Never {
    /// A BracketAsync that runs a fresh non-failing `Task` per call;
    /// `dispose` is a no-op.
    static func fromTask(
        _ makeTask: @escaping () -> Task<R, Never>
    ) -> BracketAsync<R, Never> where R: Sendable {
        fromAcquire { .success(await makeTask().value) }
    }
}
