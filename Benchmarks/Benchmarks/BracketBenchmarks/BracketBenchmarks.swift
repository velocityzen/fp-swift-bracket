import Benchmark
import BenchmarkSupport
import FPBracket

// `Bracket`: a call, and every operator that builds one bracket from
// another. Brackets are built once, outside the measured loop, so the
// numbers are the cost of a call; "(baseline)" entries do the same job by
// hand.

/// Acquires, uses and releases `value` by hand, with `Bracket`'s semantics:
/// a failed acquire skips the rest, and a failed release wins over the
/// body's result.
func manual(_ value: Int, _ body: (Int) -> IntResult) -> IntResult {
    switch acquire(value) {
        case .failure(let error):
            return .failure(error)
        case .success(let resource):
            let result = body(resource)
            if case .failure(let error) = release(resource) {
                return .failure(error)
            }
            return result
    }
}

/// `manual` nested `depth` levels deep: acquires outside in, releases inside
/// out, and releases the outer resources when an inner acquire fails.
func manualNested(depth: Int, _ body: (Int) -> IntResult) -> IntResult {
    guard depth > 1 else { return manual(depth, body) }
    return manual(depth) { _ in manualNested(depth: depth - 1, body) }
}

let benchmarks: @Sendable () -> Void = {
    let bracket = Bracket<Int, BenchError>(
        acquire: { acquire(1) },
        dispose: { release($0) }
    )
    let inner = Bracket<Int, BenchError>(
        acquire: { acquire(2) },
        dispose: { release($0) }
    )

    // MARK: Call

    Benchmark("defer (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(
                { () -> IntResult in
                    guard case .success(let resource) = acquire(1) else {
                        return .failure(BenchError())
                    }
                    defer { _ = release(resource) }
                    return use(resource)
                }()
            )
        }
    }

    Benchmark("acquire/use/release (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(manual(1, use))
        }
    }

    Benchmark("Bracket", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(bracket(use))
        }
    }

    // Builds the bracket in the loop, around a captured value, as a call
    // site that makes its bracket inline does.
    Benchmark("Bracket built per call", configuration: .bracket()) { benchmark in
        for index in benchmark.scaledIterations {
            let built = Bracket<Int, BenchError>(
                acquire: { acquire(index) },
                dispose: { release($0) }
            )
            blackHole(built(use))
        }
    }

    Benchmark("acquire/use (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(acquire(1).flatMap(use))
        }
    }

    let fromAcquire = Bracket<Int, BenchError>.fromAcquire { acquire(1) }
    Benchmark("fromAcquire", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(fromAcquire(use))
        }
    }

    // MARK: map / mapError

    Benchmark("map (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(manual(1) { use($0 &+ 1) })
        }
    }

    let mapped = bracket.map { $0 &+ 1 }
    Benchmark("map", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(mapped(use))
        }
    }

    Benchmark("mapError (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(
                { () -> Result<Int, MappedError> in
                    switch acquire(1) {
                        case .failure(let error):
                            return .failure(MappedError(error))
                        case .success(let resource):
                            let result = use(resource).mapError(MappedError.init)
                            if case .failure(let error) = release(resource) {
                                return .failure(MappedError(error))
                            }
                            return result
                    }
                }()
            )
        }
    }

    let mappedError = bracket.mapError(MappedError.init)
    Benchmark("mapError", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(mappedError { use($0).mapError(MappedError.init) })
        }
    }

    // MARK: flatMap / tap / do-notation

    Benchmark("nested (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(manualNested(depth: 2, use))
        }
    }

    let flatMapped = bracket.flatMap { _ in inner }
    Benchmark("flatMap", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(flatMapped(use))
        }
    }

    let tapped = bracket.tap { _ in inner }
    Benchmark("tap", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(tapped(use))
        }
    }

    let pipeline = BracketDo<BenchError>()
        .bind { bracket }
        .bind { _ in inner }
        .let { outer, inner in outer &+ inner }
    Benchmark("do-notation", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(pipeline { _, _, sum in use(sum) })
        }
    }

    Benchmark("nested (baseline)", configuration: .bracket(["depth": "8"])) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(manualNested(depth: 8, use))
        }
    }

    let chain = (2...8).reduce(bracket) { chain, level in
        let next = Bracket<Int, BenchError>(
            acquire: { acquire(level) },
            dispose: { release($0) }
        )
        return chain.flatMap { _ in next }
    }
    Benchmark("flatMap chain", configuration: .bracket(["depth": "8"])) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(chain(use))
        }
    }
}
