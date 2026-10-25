import FP

public extension BracketAsync where E == any Error {
    /// A service bracket from throwing code, bridged into the `Result`
    /// channel exactly once with `Result.fromAsync`. Use it at the adapter
    /// edge only; the thrown error is kept as the failure.
    ///
    /// ```swift
    /// let withSession = BracketAsync.throwing(
    ///     acquire: { try await client.openSession() },
    ///     dispose: { session in try await session.close() }
    /// )
    ///
    /// let profile = await withSession { session in
    ///     await Result.fromAsync { try await session.fetchProfile() }
    /// }
    /// ```
    ///
    /// Semantics match ``init(acquire:dispose:)``: a throwing `acquire`
    /// skips `dispose`, and an error thrown by `dispose` wins over the
    /// body's outcome. Under cancellation, a `dispose` that awaits
    /// cancellation-aware work throws `CancellationError`, which then
    /// becomes the result; see <doc:Cancellation>.
    static func throwing(
        acquire: @escaping () async throws -> R,
        dispose: @escaping (R) async throws -> Void
    ) -> BracketAsync<R, any Error> {
        BracketAsync(
            acquire: { await Result.fromAsync(acquire) },
            dispose: { resource in await Result.fromAsync { try await dispose(resource) } }
        )
    }
}
