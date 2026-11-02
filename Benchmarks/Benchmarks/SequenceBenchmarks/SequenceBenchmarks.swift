import Benchmark
import BenchmarkSupport
import FPBracket

// `Array.sequence()` for `Bracket` and `BracketAsync`, at `n: 16` and
// `n: 1024` brackets, to separate the fixed cost of a call from its cost per
// bracket: every count per bracket should stay flat as `n` grows, which is
// the O(N) the implementation documents. The array of brackets is built
// once, outside the measured loop; "(baseline)" entries acquire and release
// the same resources by hand.

/// Acquires `0..<n` left to right, runs `body`, then releases right to
/// left, with `sequence()`'s semantics: a failed acquire releases what was
/// acquired, and the first failed release wins over the body's result.
func manualLoop(_ n: Int, _ body: ([Int]) -> IntResult) -> IntResult {
    var values: [Int] = []
    values.reserveCapacity(n)
    for index in 0..<n {
        switch acquire(index) {
            case .failure(let error):
                for value in values.reversed() {
                    _ = release(value)
                }
                return .failure(error)
            case .success(let value):
                values.append(value)
        }
    }
    let result = body(values)
    var firstError: BenchError?
    for value in values.reversed() {
        if case .failure(let error) = release(value), firstError == nil {
            firstError = error
        }
    }
    return firstError.map { .failure($0) } ?? result
}

/// `manualLoop` with async sources.
func manualLoopAsync(_ n: Int, _ body: ([Int]) async -> IntResult) async -> IntResult {
    var values: [Int] = []
    values.reserveCapacity(n)
    for index in 0..<n {
        switch await acquireAsync(index) {
            case .failure(let error):
                for value in values.reversed() {
                    _ = await releaseAsync(value)
                }
                return .failure(error)
            case .success(let value):
                values.append(value)
        }
    }
    let result = await body(values)
    var firstError: BenchError?
    for value in values.reversed() {
        if case .failure(let error) = await releaseAsync(value), firstError == nil {
            firstError = error
        }
    }
    return firstError.map { .failure($0) } ?? result
}

/// `manualLoop` over one acquire and one dispose closure per resource.
func closureLoop(
    _ acquires: [() -> IntResult],
    _ disposes: [(Int) -> VoidResult],
    _ body: ([Int]) -> IntResult
) -> IntResult {
    var values: [Int] = []
    values.reserveCapacity(acquires.count)
    for acquire in acquires {
        switch acquire() {
            case .failure(let error):
                for index in values.indices.reversed() {
                    _ = disposes[index](values[index])
                }
                return .failure(error)
            case .success(let value):
                values.append(value)
        }
    }
    let result = body(values)
    var firstError: BenchError?
    for index in values.indices.reversed() {
        if case .failure(let error) = disposes[index](values[index]), firstError == nil {
            firstError = error
        }
    }
    return firstError.map { .failure($0) } ?? result
}

/// `closureLoop` with async closures.
func closureLoopAsync(
    _ acquires: [() async -> IntResult],
    _ disposes: [(Int) async -> VoidResult],
    _ body: ([Int]) async -> IntResult
) async -> IntResult {
    var values: [Int] = []
    values.reserveCapacity(acquires.count)
    for acquire in acquires {
        switch await acquire() {
            case .failure(let error):
                for index in values.indices.reversed() {
                    _ = await disposes[index](values[index])
                }
                return .failure(error)
            case .success(let value):
                values.append(value)
        }
    }
    let result = await body(values)
    var firstError: BenchError?
    for index in values.indices.reversed() {
        if case .failure(let error) = await disposes[index](values[index]), firstError == nil {
            firstError = error
        }
    }
    return firstError.map { .failure($0) } ?? result
}

let benchmarks: @Sendable () -> Void = {
    for n in [16, 1024] {
        let tags = ["n": "\(n)"]

        let brackets = (0..<n).map { index in
            Bracket<Int, BenchError>(acquire: { acquire(index) }, dispose: { release($0) })
        }
        let sequenced = brackets.sequence()

        Benchmark("manual loop (baseline)", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(manualLoop(n) { use($0.count) })
            }
        }

        // The same job by hand: one acquire and one dispose closure per
        // resource, as distinct brackets have.
        let acquires: [() -> IntResult] = (0..<n).map { index in { acquire(index) } }
        let disposes: [(Int) -> VoidResult] = (0..<n).map { _ in { release($0) } }
        Benchmark("closure loop (baseline)", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(closureLoop(acquires, disposes) { use($0.count) })
            }
        }

        Benchmark("sequence", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(sequenced { use($0.count) })
            }
        }

        let asyncBrackets = (0..<n).map { index in
            BracketAsync<Int, BenchError>(
                acquire: { await acquireAsync(index) },
                dispose: { await releaseAsync($0) }
            )
        }
        let asyncSequenced = asyncBrackets.sequence()

        Benchmark("manual loop async (baseline)", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(await manualLoopAsync(n) { await useAsync($0.count) })
            }
        }

        let asyncAcquires: [() async -> IntResult] = (0..<n).map { index in
            { await acquireAsync(index) }
        }
        let asyncDisposes: [(Int) async -> VoidResult] = (0..<n).map { _ in
            { await releaseAsync($0) }
        }
        Benchmark("closure loop async (baseline)", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(
                    await closureLoopAsync(asyncAcquires, asyncDisposes) {
                        await useAsync($0.count)
                    }
                )
            }
        }

        Benchmark("sequence async", configuration: .bracket(tags)) { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(await asyncSequenced { await useAsync($0.count) })
            }
        }
    }
}
