#  ``FPBracket``

A monadic acquire / use / release pattern for Swift's `Result` and async `Result` workflows.

## Overview

It packages a resource's lifecycle — acquire, use, release — into a reusable
value that is also a monad, so resources compose by `flatMap`.

```swift
let withFile: Bracket<File, MyError> = Bracket(
    acquire: { openFile(path) },
    dispose: { file in closeFile(file) }
)

let contents = withFile { file in readContents(file) }
let lines    = withFile { file in countLines(file) }
```

**Semantics**

- If `acquire` fails, `dispose` is **not** called.
- Otherwise the body runs and then `dispose` runs unconditionally — even on body failure.
- A `dispose` failure wins over the body's outcome.

**Composition**

- ``Bracket/map(_:)`` transforms the visible resource type without changing the
  underlying acquire / dispose.
- ``Bracket/flatMap(_:)`` nests a second bracket inside the first. Acquire
  order is outer-then-inner; release order is inner-then-outer. If inner's
  acquire fails, outer is released before the failure is returned.

**Do-notation**

``BracketDo`` (and ``BracketAsyncDo``) start `bind` / `let` chains that
accumulate resources into a flat tuple — up to 10 elements, past which
results nest instead of flattening:

```swift
let pipeline = BracketDo<MyError>()
    .bind { withFile }                  // Bracket<File, MyError>
    .bind { file in withDB(file) }      // Bracket<(File, DB), MyError>
    .let { _, db in derivedKey(db) }    // Bracket<(File, DB, Key), MyError>
```

**Collections**

``Swift/Array/sequence()->Bracket<[R],E>`` combines `[Bracket<R, E>]` into a
single `Bracket<[R], E>`; ``Swift/Array/traverse(_:)->Bracket<[R],E>`` maps
and sequences in one step. Resources are acquired left-to-right and released
right-to-left, with cleanup on partial failure.

The async counterpart ``BracketAsync`` follows the same semantics over
`async` acquire / dispose / use callbacks.

## Topics

### Sync resource lifecycle

- ``Bracket``
- ``Bracket/init(acquire:dispose:)``
- ``Bracket/of(_:)``
- ``Bracket/fromAcquire(_:)``
- ``Bracket/callAsFunction(_:)``
- ``Bracket/map(_:)``
- ``Bracket/flatMap(_:)``
- ``Bracket/tap(_:)``
- ``Bracket/as(_:)``
- ``Bracket/asUnit()``
- ``Swift/Array/sequence()->Bracket<[R],E>``
- ``Swift/Array/traverse(_:)->Bracket<[R],E>``

### Sync do-notation

- ``BracketDo``
- ``BracketDo/bind(_:)``
- ``BracketDo/let(_:)``

### Async resource lifecycle

- ``BracketAsync``
- ``BracketAsync/init(acquire:dispose:)``
- ``BracketAsync/of(_:)``
- ``BracketAsync/fromAcquire(_:)``
- ``BracketAsync/fromTask(_:)->BracketAsync<R,E>``
- ``BracketAsync/fromTask(_:)->BracketAsync<R,Error>``
- ``BracketAsync/fromTask(_:)->BracketAsync<R,Never>``
- ``BracketAsync/callAsFunction(_:)``
- ``BracketAsync/map(_:)``
- ``BracketAsync/flatMap(_:)``
- ``BracketAsync/tap(_:)``
- ``BracketAsync/as(_:)``
- ``BracketAsync/asUnit()``
- ``Swift/Array/sequence()->BracketAsync<[R],E>``
- ``Swift/Array/traverse(_:)->BracketAsync<[R],E>``

### Async do-notation

- ``BracketAsyncDo``
- ``BracketAsyncDo/bind(_:)``
- ``BracketAsyncDo/let(_:)``
