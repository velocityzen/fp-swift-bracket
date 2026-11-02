# Benchmarks

Performance benchmarks for FPBracket, built on [ordo-one/benchmark](https://github.com/ordo-one/benchmark). They live in their own package so the library never depends on the benchmark package.

Every benchmark records wall clock and CPU time, instructions, malloc count and bytes, bytes not freed, object allocations, and retain and release counts. All values are **per call** of the bracket under test.

## Suites

| Target | Covers |
| --- | --- |
| `BracketBenchmarks` | a `Bracket` call, one built per call, `fromAcquire`, `map`, `mapError`, `flatMap`, `tap`, do-notation and an eight-deep `flatMap` chain |
| `BracketAsyncBenchmarks` | the same for `BracketAsync`, plus `throwing`, `uncancellableDispose` and the three `fromTask` forms |
| `SequenceBenchmarks` | `Array.sequence()` for `Bracket` and `BracketAsync` at `n: 16` and `n: 1024` brackets |

Brackets are built once, outside the measured loop, so the numbers are the cost of a call, apart from the "built per call" entries. Acquire, use and release are opaque functions on an `Int` that never suspend or allocate, so the numbers are the bracket's own overhead rather than the work it runs.

Entries marked `(baseline)` do the same job by hand: a plain `defer`, a manual acquire/use/release with the bracket's error semantics, nested manual brackets, `do`/`catch`, a `Task` with a cancellation handler, a loop over an array. The gap between a baseline and the operator next to it is what an optimization can win back. `SequenceBenchmarks` has two: `manual loop` calls the same acquire and release functions directly, and `closure loop` calls one stored acquire and one stored dispose closure per resource, as an array of distinct brackets must. `sequence` should match `closure loop`. It runs at two sizes so that cost per bracket is visible: it should stay flat as `n` grows, which is the O(N) that `Array+Bracket.swift` documents.

## Running

Requires Swift 6.3 or later. Malloc statistics come from the benchmark package's malloc interposer, so there is nothing to install.

Run everything from this directory:

```bash
swift package benchmark
```

Run one suite, or the benchmarks whose names match a regular expression. The expression must match the whole name without its `(n: …)` or `(depth: …)` tags, so a filter selects every size of a benchmark:

```bash
swift package benchmark --target BracketAsyncBenchmarks
```

```bash
swift package benchmark --filter "sequence.*"
```

List the benchmarks without running them:

```bash
swift package benchmark list
```

## Comparing before and after a change

Record a baseline, make the change, then compare the new code against it:

```bash
swift package --allow-writing-to-package-directory benchmark baseline update main
```

```bash
swift package benchmark baseline compare main
```

Baselines are saved in `.benchmarkBaselines/`, which is not committed: they are only comparable on the machine that recorded them.

Malloc, object-allocation and ARC counts are the same on every run of the same code, so they are the numbers to watch first. Times move with the machine's load; close other work before comparing them.

`baseline check` fails only when one of those four counts gets worse by more than 5% at the median; times and the other metrics are reported by `compare` but never fail a check. The tolerance is `checkedTolerance` in [BenchmarkSupport.swift](Sources/BenchmarkSupport/BenchmarkSupport.swift).

```bash
swift package benchmark baseline check main
```

## Continuous integration

The [Benchmarks workflow](../.github/workflows/benchmarks.yml) benchmarks every push to `main` against the commit it was pushed on top of, and every pull request against its base branch. The job summary lists every metric's change, and the job fails when an allocation or ARC count regresses; the job log shows every count that crossed its threshold. An improvement passes.

`baseline check base head` builds nothing: it compares two recorded baselines and takes its thresholds from the base one. So a change to the thresholds or the tolerance applies from the commit after it, and the commit that makes it is still checked against the old ones.

## Finding where allocations come from

Print the call stacks behind each benchmark's allocations, most frequent first:

```bash
swift package benchmark --target BracketBenchmarks --filter "flatMap" --allocation-stacks
```

## Profiling

Each suite is an ordinary executable that runs all of its benchmarks when launched on its own, so it can be profiled in Instruments or debugged in lldb:

```bash
swift build -c release --product BracketBenchmarks
```
