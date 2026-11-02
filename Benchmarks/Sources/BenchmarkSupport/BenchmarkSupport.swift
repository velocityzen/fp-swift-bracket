import Benchmark

/// Metrics recorded by every FPBracket benchmark: time, instructions, heap
/// traffic and ARC traffic. Every value is reported per call of the API
/// under test.
public let bracketMetrics: [BenchmarkMetric] = [
    .wallClock,
    .cpuTotal,
    .throughput,
    .instructions,
    .mallocCountTotal,
    .mallocBytesCount,
    .memoryLeakedBytes,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
]

/// The metrics `baseline check` fails on. Allocation and ARC counts barely
/// move between runs of the same code, while times swing with the machine's
/// load, so times are reported but never fail a check.
public let checkedMetrics: [BenchmarkMetric] = [
    .mallocCountTotal,
    .objectAllocCount,
    .retainCount,
    .releaseCount,
]

/// How far, in percent, a checked metric's median may move before
/// `baseline check` reports it.
///
/// Every benchmark here allocates and retains the same way on every call, so
/// two runs of the same code agree exactly. That includes `fromTask` and
/// `uncancellableDispose`, which start exactly one task per call rather than
/// starting them on demand. One allocation or retain more per call is at
/// least 5% of every count up to 20, and no count here is above 20: the
/// largest, 14 retains and releases, is the eight-deep `flatMap` chain's.
let checkedTolerance = 5.0

func bracketThresholds() -> [BenchmarkMetric: BenchmarkThresholds] {
    Dictionary(
        uniqueKeysWithValues: bracketMetrics.map { metric in
            let thresholds =
                checkedMetrics.contains(metric)
                ? BenchmarkThresholds(relative: [.p50: checkedTolerance])
                : BenchmarkThresholds()
            return (metric, thresholds)
        }
    )
}

public extension Benchmark.Configuration {
    /// The configuration every FPBracket benchmark uses.
    ///
    /// Each sample runs `scaling` calls in a `benchmark.scaledIterations`
    /// loop, and the scaled metrics are divided back to a single call. Use
    /// `.kilo` for calls in the micro- or nanosecond range, so timer and
    /// sampling overhead stays out of the numbers, and `.one` for calls that
    /// already take a millisecond or so.
    static func bracket(
        _ tags: [String: String] = [:],
        scaling: BenchmarkScalingFactor = .kilo
    ) -> Self {
        .init(
            metrics: bracketMetrics,
            tags: tags,
            warmupIterations: 5,
            scalingFactor: scaling,
            maxDuration: .seconds(1),
            maxIterations: 10_000,
            thresholds: bracketThresholds()
        )
    }
}

// MARK: - Sources

// The resource every benchmark acquires, uses and releases is an `Int`, and
// acquire, use and release are the functions below. None of them suspends
// or allocates, so a benchmark measures the bracket around them. They are
// `@inline(never)` so the optimizer can fold neither a bracket nor the
// hand-written baseline next to it into a constant.

/// The failure every failing benchmark source returns.
public struct BenchError: Error, Equatable, Sendable {
    public init() {}
}

/// The error `mapError` benchmarks map `BenchError` to.
public struct MappedError: Error, Equatable, Sendable {
    public init(_ error: BenchError) {}
}

public typealias IntResult = Result<Int, BenchError>
public typealias VoidResult = Result<Void, BenchError>

@inline(never)
public func acquire(_ value: Int) -> IntResult {
    .success(value)
}

@inline(never)
public func release(_ value: Int) -> VoidResult {
    blackHole(value)
    return .success(())
}

@inline(never)
public func use(_ value: Int) -> IntResult {
    .success(value &* 2)
}

@inline(never)
public func acquireAsync(_ value: Int) async -> IntResult {
    .success(value)
}

@inline(never)
public func releaseAsync(_ value: Int) async -> VoidResult {
    blackHole(value)
    return .success(())
}

@inline(never)
public func useAsync(_ value: Int) async -> IntResult {
    .success(value &* 2)
}

/// Throwing sources, for `BracketAsync.throwing` and its `do`/`catch`
/// baseline.
@inline(never)
public func openResource(_ value: Int) async throws -> Int {
    value
}

@inline(never)
public func closeResource(_ value: Int) async throws {
    blackHole(value)
}
