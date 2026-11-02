import Benchmark
import BenchmarkSupport
import FPBracket

// `BracketAsync`: a call, every operator that builds one bracket from
// another, the throwing and uncancellable-dispose forms, and `fromTask`.
// Brackets are built once, outside the measured loop, so the numbers are
// the cost of a call; "(baseline)" entries do the same job by hand. No
// source suspends, so a call that starts no task never suspends either.

/// Acquires, uses and releases `value` by hand, with `BracketAsync`'s
/// semantics: a failed acquire skips the rest, and a failed release wins
/// over the body's result.
func manual(_ value: Int, _ body: (Int) async -> IntResult) async -> IntResult {
    switch await acquireAsync(value) {
        case .failure(let error):
            return .failure(error)
        case .success(let resource):
            let result = await body(resource)
            if case .failure(let error) = await releaseAsync(resource) {
                return .failure(error)
            }
            return result
    }
}

/// `manual` nested `depth` levels deep: acquires outside in, releases inside
/// out, and releases the outer resources when an inner acquire fails.
func manualNested(depth: Int, _ body: (Int) async -> IntResult) async -> IntResult {
    guard depth > 1 else { return await manual(depth, body) }
    return await manual(depth) { _ in await manualNested(depth: depth - 1, body) }
}

let benchmarks: @Sendable () -> Void = {
    let bracket = BracketAsync<Int, BenchError>(
        acquire: { await acquireAsync(1) },
        dispose: { await releaseAsync($0) }
    )
    let inner = BracketAsync<Int, BenchError>(
        acquire: { await acquireAsync(2) },
        dispose: { await releaseAsync($0) }
    )

    // MARK: Call

    Benchmark("defer (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            guard case .success(let resource) = await acquireAsync(1) else {
                continue
            }
            defer { _ = await releaseAsync(resource) }
            blackHole(await useAsync(resource))
        }
    }

    Benchmark("acquire/use/release (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await manual(1, useAsync))
        }
    }

    Benchmark("BracketAsync", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await bracket(useAsync))
        }
    }

    // Builds the bracket in the loop, around a captured value, as a call
    // site that makes its bracket inline does.
    Benchmark("BracketAsync built per call", configuration: .bracket()) { benchmark in
        for index in benchmark.scaledIterations {
            let built = BracketAsync<Int, BenchError>(
                acquire: { await acquireAsync(index) },
                dispose: { await releaseAsync($0) }
            )
            blackHole(await built(useAsync))
        }
    }

    Benchmark("acquire/use (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await acquireAsync(1).flatMapAsync(useAsync))
        }
    }

    let fromAcquire = BracketAsync<Int, BenchError>.fromAcquire { await acquireAsync(1) }
    Benchmark("fromAcquire", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await fromAcquire(useAsync))
        }
    }

    // MARK: map / mapError

    Benchmark("map (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await manual(1) { await useAsync($0 &+ 1) })
        }
    }

    let mapped = bracket.map { $0 &+ 1 }
    Benchmark("map", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await mapped(useAsync))
        }
    }

    Benchmark("mapError (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            switch await acquireAsync(1) {
                case .failure(let error):
                    blackHole(Result<Int, MappedError>.failure(MappedError(error)))
                case .success(let resource):
                    var result = await useAsync(resource).mapError(MappedError.init)
                    if case .failure(let error) = await releaseAsync(resource) {
                        result = .failure(MappedError(error))
                    }
                    blackHole(result)
            }
        }
    }

    let mappedError = bracket.mapError(MappedError.init)
    Benchmark("mapError", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await mappedError { await useAsync($0).mapError(MappedError.init) })
        }
    }

    // MARK: flatMap / tap / do-notation

    Benchmark("nested (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await manualNested(depth: 2, useAsync))
        }
    }

    let flatMapped = bracket.flatMap { _ in inner }
    Benchmark("flatMap", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await flatMapped(useAsync))
        }
    }

    let tapped = bracket.tap { _ in inner }
    Benchmark("tap", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await tapped(useAsync))
        }
    }

    let pipeline = BracketAsyncDo<BenchError>()
        .bind { bracket }
        .bind { _ in inner }
        .let { outer, inner in outer &+ inner }
    Benchmark("do-notation", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await pipeline { _, _, sum in await useAsync(sum) })
        }
    }

    Benchmark("nested (baseline)", configuration: .bracket(["depth": "8"])) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await manualNested(depth: 8, useAsync))
        }
    }

    let chain = (2...8).reduce(bracket) { chain, level in
        let next = BracketAsync<Int, BenchError>(
            acquire: { await acquireAsync(level) },
            dispose: { await releaseAsync($0) }
        )
        return chain.flatMap { _ in next }
    }
    Benchmark("flatMap chain", configuration: .bracket(["depth": "8"])) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await chain(useAsync))
        }
    }

    // MARK: Throwing

    Benchmark("do/catch (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            let result: Result<Int, any Error>
            do {
                let resource = try await openResource(1)
                let used = await useAsync(resource).mapError { $0 as any Error }
                do {
                    try await closeResource(resource)
                    result = used
                } catch {
                    result = .failure(error)
                }
            } catch {
                result = .failure(error)
            }
            blackHole(result)
        }
    }

    let throwing = BracketAsync.throwing(
        acquire: { try await openResource(1) },
        dispose: { try await closeResource($0) }
    )
    Benchmark("throwing", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await throwing { await useAsync($0).mapError { $0 as any Error } })
        }
    }

    // MARK: Tasks

    // These start one task per call, so they take microseconds rather than
    // nanoseconds.

    Benchmark("release in a Task (baseline)", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            switch await acquireAsync(1) {
                case .failure(let error):
                    blackHole(IntResult.failure(error))
                case .success(let resource):
                    var result = await useAsync(resource)
                    let released = await Task { await releaseAsync(resource) }.value
                    if case .failure(let error) = released {
                        result = .failure(error)
                    }
                    blackHole(result)
            }
        }
    }

    let uncancellable = BracketAsync<Int, BenchError>(
        acquire: { await acquireAsync(1) },
        uncancellableDispose: { await releaseAsync($0) }
    )
    Benchmark("uncancellableDispose", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await uncancellable(useAsync))
        }
    }

    Benchmark("Task with cancellation handler (baseline)", configuration: .bracket()) {
        benchmark in
        for _ in benchmark.scaledIterations {
            let task = Task { await acquireAsync(1) }
            let acquired = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            blackHole(await acquired.flatMapAsync(useAsync))
        }
    }

    let fromTask = BracketAsync<Int, BenchError>.fromTask { Task { await acquireAsync(1) } }
    Benchmark("fromTask", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await fromTask(useAsync))
        }
    }

    let fromThrowingTask = BracketAsync<Int, any Error>.fromTask {
        Task { try await openResource(1) }
    }
    Benchmark("fromTask throwing", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await fromThrowingTask { await useAsync($0).mapError { $0 as any Error } })
        }
    }

    let fromNonFailingTask = BracketAsync<Int, Never>.fromTask { Task { 1 } }
    Benchmark("fromTask non-failing", configuration: .bracket()) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(await fromNonFailingTask { .success($0 &* 2) })
        }
    }
}
