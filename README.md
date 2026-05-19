# fp-swift-bracket

[![Swift](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-bracket%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/velocityzen/fp-swift-bracket)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fvelocityzen%2Ffp-swift-bracket%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/velocityzen/fp-swift-bracket)

A monadic acquire / use / release pattern for Swift's `Result` and async `Result` workflows.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/velocityzen/fp-swift-bracket", from: "1.0.0")
]
```

Then add `FPBracket` to your target's dependencies.

## Why

Resources with a lifecycle — files, connections, locks, transactions — are awkward in `Result`-based code: every call site has to remember to release, even when the body fails. `Bracket` captures the lifecycle as a reusable value:

```swift
let withFile: Bracket<MyError, File> = Bracket(
    acquire: { openFile(path) },
    dispose: { file in closeFile(file) }
)

// Reuse with different bodies — each call acquires, runs, releases.
let contents = withFile { file in readContents(file) }
let lines    = withFile { file in countLines(file) }
```

Semantics:

- `acquire` failure short-circuits — `dispose` is **not** called.
- Otherwise the body runs and then `dispose` runs unconditionally — even on body failure.
- A `dispose` failure wins over the body's outcome.

## Composition

`Bracket` is a monad. The standard combinators apply:

```swift
// map: transform the visible resource type
let withFileSize = withFile.map { file in file.size }

// flatMap: nest two scopes — acquire outer→inner, release inner→outer
let withFileAndDB = withFile.flatMap { file in withDB(file) }

// tap: run a side-effecting bracket, keep the outer resource
let withFileAndLock = withFile.tap { file in withLock(file) }
```

### Do-notation

For pipelines that accumulate several resources into a tuple:

```swift
let pipeline = BracketDo<MyError>()
    .bind { withFile }                          // Bracket<MyError, File>
    .bind { file in withDB(file) }              // Bracket<MyError, (File, DB)>
    .let  { _, db in derivedKey(db) }           // Bracket<MyError, (File, DB, Key)>
    .map  { file, _, key in (file, key) }       // Bracket<MyError, (File, Key)>

let result = pipeline { (file, key) in encrypt(file, key) }
```

### Sequence / traverse over arrays

```swift
// Open one file per path, scope all of them, then close in reverse
let combined = paths.traverse { withFile($0) }
let summary = combined { files in summarize(files) }

// Or build the brackets first, then sequence
let brackets: [Bracket<E, Connection>] = configs.map(withConnection)
let scoped = brackets.sequence()
```

Resources are acquired left-to-right and released right-to-left. If any acquire fails, previously acquired resources are released and the failure is propagated.

## Async

`BracketAsync<E, R>` mirrors every operation above for `async` acquire / dispose / use:

```swift
let withConnection: BracketAsync<DBError, Connection> = BracketAsync(
    acquire: { await pool.checkOut() },
    dispose: { conn in await pool.release(conn) }
)

let rows = await withConnection { conn in
    await conn.query("SELECT * FROM users")
}
```

`BracketAsyncDo<E>`, `.tap`, `.sequence()`, `.traverse(_:)` are all available on the async side.

## Documentation

Full API reference: [swiftpackageindex.com/velocityzen/fp-swift-bracket/documentation/fpbracket](https://swiftpackageindex.com/velocityzen/fp-swift-bracket/documentation/fpbracket)

## Note on trailing-closure syntax

`Bracket` / `BracketAsync` are invoked via `callAsFunction`. Swift's trailing-closure rule attaches `{ … }` to the *method call*, not to its result, so an immediate call on a chained expression won't parse:

```swift
// ❌ closure attaches to .flatMap(_:)
let result = base.flatMap(next) { r in … }

// ✅ bind to a name first
let bracket = base.flatMap(next)
let result = bracket { r in … }
```

In real usage brackets are virtually always assigned to a `let` before being scoped, so this rarely comes up.

## License

[MIT](LICENSE)
