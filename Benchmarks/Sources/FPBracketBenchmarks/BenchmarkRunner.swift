import FPBracket

// A dependency-free micro-benchmark harness. Run from the repo root:
//
//     swift run --package-path Benchmarks -c release FPBracketBenchmarks
//
// Pass `--quick` for the reduced workload CI uses as a smoke test.
//
// Each number is the median of many runs, so one-off scheduler hiccups don't
// skew results. `Array.sequence` reports a per-element cost on purpose: it
// should stay roughly flat as N grows — that's the O(N) guarantee documented
// in Array+Bracket.swift made visible.

enum BenchmarkError: Error {
    case unreachable
}

private let clock = ContinuousClock()

// MARK: - Measurement

private func measure(
    _ label: String,
    iterations: Int,
    per: Int,
    unit: String,
    _ body: () -> Void
) {
    body()  // warm-up
    var samples: [Duration] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        samples.append(clock.measure(body))
    }
    report(label, samples, per: per, unit: unit)
}

private func measureAsync(
    _ label: String,
    iterations: Int,
    per: Int,
    unit: String,
    _ body: () async -> Void
) async {
    await body()  // warm-up
    var samples: [Duration] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        samples.append(await clock.measure(body))
    }
    report(label, samples, per: per, unit: unit)
}

private func report(_ label: String, _ samples: [Duration], per: Int, unit: String) {
    let sorted = samples.sorted()
    let median = sorted[sorted.count / 2]
    print(
        pad(label, to: 48)
            + pad("median " + format(median), to: 20)
            + format(median / per) + "/" + unit
    )
}

private func format(_ duration: Duration) -> String {
    let attoseconds =
        Double(duration.components.seconds) * 1e18 + Double(duration.components.attoseconds)
    let microseconds = attoseconds / 1e12
    if microseconds >= 1_000_000 {
        return rounded(microseconds / 1_000_000) + " s"
    }
    if microseconds >= 1_000 {
        return rounded(microseconds / 1_000) + " ms"
    }
    return rounded(microseconds) + " µs"
}

private func rounded(_ value: Double) -> String {
    String((value * 100).rounded() / 100)
}

private func pad(_ string: String, to width: Int) -> String {
    let shortfall = width - string.count
    return shortfall > 0 ? string + String(repeating: " ", count: shortfall) : string
}

// MARK: - Subjects

private func intBracket(_ value: Int) -> Bracket<Int, BenchmarkError> {
    Bracket(
        acquire: { .success(value) },
        dispose: { _ in .success(()) }
    )
}

private func intBracketAsync(_ value: Int) -> BracketAsync<Int, BenchmarkError> {
    BracketAsync(
        acquire: { .success(value) },
        dispose: { _ in .success(()) }
    )
}

// MARK: - Benchmarks

private func benchmarkSequence(sizes: [Int], iterations: Int) {
    for n in sizes {
        let brackets = (0..<n).map(intBracket)
        measure(
            "Array.sequence, N=\(n)",
            iterations: iterations,
            per: n,
            unit: "element"
        ) {
            let scoped: Bracket<[Int], BenchmarkError> = brackets.sequence()
            let result = scoped { values in .success(values.count) }
            precondition((try? result.get()) == n, "sequence returned an unexpected result")
        }
    }
}

private func benchmarkFlatMapChain(depths: [Int], iterations: Int) {
    for depth in depths {
        measure(
            "flatMap chain (build + run), depth=\(depth)",
            iterations: iterations,
            per: depth,
            unit: "level"
        ) {
            var bracket = intBracket(0)
            for next in 1...depth {
                bracket = bracket.flatMap { _ in intBracket(next) }
            }
            let result = bracket { value in .success(value) }
            precondition((try? result.get()) == depth, "chain returned an unexpected result")
        }
    }
}

private func benchmarkCallOverhead(calls: Int, iterations: Int) {
    let bracket = intBracket(1)
    measure(
        "Bracket call, \(calls) acquire/use/release",
        iterations: iterations,
        per: calls,
        unit: "call"
    ) {
        var total = 0
        for _ in 0..<calls {
            let result = bracket { value in .success(value) }
            total += (try? result.get()) ?? 0
        }
        precondition(total == calls, "call loop returned an unexpected total")
    }
}

private func benchmarkCallOverheadAsync(calls: Int, iterations: Int) async {
    let bracket = intBracketAsync(1)
    await measureAsync(
        "BracketAsync call, \(calls) acquire/use/release",
        iterations: iterations,
        per: calls,
        unit: "call"
    ) {
        var total = 0
        for _ in 0..<calls {
            let result = await bracket { value in .success(value) }
            total += (try? result.get()) ?? 0
        }
        precondition(total == calls, "async call loop returned an unexpected total")
    }
}

// MARK: - Entry point

@main
struct BenchmarkRunner {
    static func main() async {
        let quick = CommandLine.arguments.contains("--quick")
        let iterations = quick ? 5 : 51
        let sizes = quick ? [10, 100] : [10, 100, 1_000]
        let depths = quick ? [10] : [10, 100]
        let calls = quick ? 1_000 : 10_000

        let mode = quick ? "quick" : "full"
        print("FPBracket benchmarks — \(mode) mode, median of \(iterations) runs")
        print("")

        benchmarkSequence(sizes: sizes, iterations: iterations)
        benchmarkFlatMapChain(depths: depths, iterations: iterations)
        benchmarkCallOverhead(calls: calls, iterations: iterations)
        await benchmarkCallOverheadAsync(calls: calls, iterations: iterations)
    }
}
