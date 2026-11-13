// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import HegelTesting

    /// One test case's policy: how often acquires and releases fail, and how
    /// big a bracket gets. Drawn per test case, so some cases fail nowhere
    /// and run deep compositions to the body, some fail every release, and
    /// some stay small.
    struct Policy: Hashable, Sendable, CustomStringConvertible {
        /// The chance that an acquire fails.
        var acquireFailure: Double
        /// The chance that a release fails.
        var releaseFailure: Double
        /// The most leaves one bracket expression has.
        var maxLeaves: Int
        /// Whether expressions have `hang` leaves. Only the cancellation
        /// property draws them: a hang runs until it is cancelled.
        var hangs = false

        var description: String {
            "acquireFailure: \(acquireFailure), releaseFailure: \(releaseFailure), "
                + "maxLeaves: \(maxLeaves)\(hangs ? ", hangs" : "")"
        }
    }

    enum BracketGen {
        /// Small values usually, so outcomes and logs are easy to read; any `Int`
        /// sometimes, so the arithmetic wraps.
        static let value: Gen<Int> = .oneOf(.int(in: 0...9), .int(), .element(of: [.max, .min]))

        /// Each draw shrinks toward the first: no failures, one leaf.
        static let policy: Gen<Policy> = Hegel.zip(
            Gen<Double>.element(of: [0.0, 0.05, 0.2, 0.5]),
            Gen<Double>.element(of: [0.0, 0.1, 0.5, 1.0]),
            // Drawing an expression costs far more than running it, about
            // the same for each node, so the leaves stay below Hegel's
            // default of 100.
            Gen<Int>.element(of: [1, 4, 10, 30])
        ).map { Policy(acquireFailure: $0, releaseFailure: $1, maxLeaves: $2) }

        /// The policy, with `hang` leaves in some test cases.
        static let cancellationPolicy: Gen<Policy> = Hegel.zip(policy, Gen<Bool>.bool()).map {
            policy,
            hangs in
            var policy = policy
            policy.hangs = hangs
            return policy
        }

        /// `.fail` with probability `rate`.
        static func outcome(failing rate: Double) -> Gen<Outcome> {
            Gen.bool(probability: rate).flatMap { fails in
                fails ? value.map { Outcome.fail($0) } : .just(.ok)
            }
        }

        static func leaf(_ policy: Policy) -> Gen<Expr> {
            var leaves: [Gen<Expr>] = [
                Hegel.zip(
                    Gen<Int>.int(),
                    outcome(failing: policy.acquireFailure),
                    outcome(failing: policy.releaseFailure),
                    Gen<LeafKind>.element(of: LeafKind.allCases)
                ).map { Expr.leaf(id: $0, acquire: $1, dispose: $2, kind: $3) },
                value.map { Expr.of($0) },
                Hegel.zip(Gen<Int>.int(), outcome(failing: policy.acquireFailure)).flatMap {
                    id,
                    outcome in
                    // Only `neverTask` can't fail.
                    let kinds = outcome == .ok ? FromKind.allCases : FromKind.failing
                    return Gen.element(of: kinds).map { Expr.fromAcquire(id: id, outcome, via: $0) }
                },
            ]
            if policy.hangs {
                leaves.append(
                    Hegel.zip(Gen<Int>.int(), Gen<FromKind>.element(of: FromKind.allCases)).map {
                        Expr.hang(id: $0, via: $1)
                    }
                )
            }
            return .oneOf(leaves)
        }

        static func expression(_ policy: Policy) -> Gen<Expr> {
            expression(policy, maxLeaves: policy.maxLeaves)
        }

        /// A smaller expression, for the many a do-notation chain or a
        /// `sequence()` holds.
        static func part(_ policy: Policy) -> Gen<Expr> {
            expression(policy, maxLeaves: min(policy.maxLeaves, 10))
        }

        static func expression(_ policy: Policy, maxLeaves: Int) -> Gen<Expr> {
            .recursive(maxLeaves: maxLeaves, leaf: leaf(policy)) { sub in
                Gen.oneOf(
                    Hegel.zip(sub, value).map { Expr.map($0, $1) },
                    Hegel.zip(sub, value).map { Expr.mapError($0, $1) },
                    Hegel.zip(sub, sub).map { Expr.flatMap($0, $1) },
                    Hegel.zip(sub, sub).map { Expr.tap($0, $1) },
                    Hegel.zip(sub, sub).map { Expr.bind($0, $1) },
                    Hegel.zip(.array(of: sub), Gen<Bool>.bool()).map {
                        Expr.sequence($0, traverse: $1)
                    },
                    Hegel.zip(sub, value).map { Expr.constant($0, $1) },
                    sub.map { Expr.unit($0) }
                )
            }
        }

        static let body: Gen<Result<Int, Code>> = .oneOf(
            value.map { Result.success($0) },
            value.map { Result.failure(Code(code: $0)) }
        )
    }

#endif
