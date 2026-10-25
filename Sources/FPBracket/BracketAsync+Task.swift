import FP

// MARK: - BracketAsync from Task

// All variants take a closure rather than a concrete `Task` on purpose:
// brackets are reusable recipes, so each call should run a fresh task. To
// scope one already-running task instead, capture it — `fromTask { shared }` —
// and every call awaits the same (memoized) value.
//
// Cancellation is forwarded: if the task awaiting the bracket is cancelled,
// the task produced by `makeTask` is cancelled too. Awaiting an unstructured
// task's `value` doesn't do this on its own. Note that a captured shared task
// is cancelled for every caller when any one of them is cancelled.

public extension BracketAsync {
    /// A BracketAsync that runs a fresh `Task` per call and yields its
    /// `Result`; `dispose` is a no-op.
    ///
    /// This is the typed-error variant: the task itself never fails, the
    /// `Result` it produces carries the bracket's error. Cancelling the
    /// caller cancels the task.
    ///
    /// ```swift
    /// let withUser = BracketAsync<User, APIError>.fromTask {
    ///     Task { await api.fetchUser() }  // Task<Result<User, APIError>, Never>
    /// }
    /// ```
    static func fromTask(
        _ makeTask: @escaping () -> Task<Result<R, E>, Never>
    ) -> BracketAsync<R, E> where R: Sendable, E: Sendable {
        fromAcquire {
            let task = makeTask()
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }
}

public extension BracketAsync where E == Error {
    /// A BracketAsync that runs a fresh throwing `Task` per call; a thrown
    /// error becomes the bracket's failure. `dispose` is a no-op. Cancelling
    /// the caller cancels the task.
    ///
    /// ```swift
    /// let withUser = BracketAsync<User, Error>.fromTask {
    ///     Task { try await api.fetchUser() }
    /// }
    /// ```
    static func fromTask(
        _ makeTask: @escaping () -> Task<R, Error>
    ) -> BracketAsync<R, Error> where R: Sendable {
        fromAcquire {
            let task = makeTask()
            return await withTaskCancellationHandler {
                await Result.fromTask(task)
            } onCancel: {
                task.cancel()
            }
        }
    }
}

public extension BracketAsync where E == Never {
    /// A BracketAsync that runs a fresh non-failing `Task` per call;
    /// `dispose` is a no-op. Cancelling the caller cancels the task.
    static func fromTask(
        _ makeTask: @escaping () -> Task<R, Never>
    ) -> BracketAsync<R, Never> where R: Sendable {
        fromAcquire {
            let task = makeTask()
            return .success(
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            )
        }
    }
}
