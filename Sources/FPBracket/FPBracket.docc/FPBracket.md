#  ``FPBracket``

A monadic acquire / use / release pattern for Swift's `Result` and async `Result` workflows.

## Overview

It packages a resource's lifecycle — acquire, use, release — into a reusable
value that is also a monad, so resources compose by `flatMap`.

```swift
let withFile: Bracket<MyError, File> = Bracket(
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

The async counterpart ``BracketAsync`` follows the same semantics over
`async` acquire / dispose / use callbacks.

## Topics

### Sync resource lifecycle

- ``Bracket``
- ``Bracket/init(acquire:dispose:)``
- ``Bracket/of(_:)``
- ``Bracket/callAsFunction(_:)``
- ``Bracket/map(_:)``
- ``Bracket/flatMap(_:)``
- ``Bracket/tap(_:)``
- ``Bracket/as(_:)``
- ``Bracket/asUnit()``

### Sync do-notation

- ``BracketDo``
- ``BracketDo/bind(_:)``
- ``BracketDo/let(_:)``

### Async resource lifecycle

- ``BracketAsync``
- ``BracketAsync/init(acquire:dispose:)``
- ``BracketAsync/of(_:)``
- ``BracketAsync/callAsFunction(_:)``
- ``BracketAsync/map(_:)``
- ``BracketAsync/flatMap(_:)``
- ``BracketAsync/tap(_:)``
- ``BracketAsync/as(_:)``
- ``BracketAsync/asUnit()``

### Async do-notation

- ``BracketAsyncDo``
- ``BracketAsyncDo/bind(_:)``
- ``BracketAsyncDo/let(_:)``
