# Handling Cancellation

How ``BracketAsync`` behaves when the calling task is cancelled, and how to
write acquire, body, and dispose callbacks that cope with it.

## Overview

Swift cancellation is cooperative. Cancelling a task doesn't stop it; it sets
a flag that stays set for the rest of the task's life. Cancellation-aware APIs
(`Task.sleep`, `URLSession`, `Task.checkCancellation()`, most networking and
I/O libraries) see the flag and bail out early.

``BracketAsync`` runs acquire, body, and dispose in the caller's task. That
gives two guarantees and one consequence:

- **Dispose is always called** after a successful acquire, exactly once, even
  if the task is cancelled. Nested brackets from ``BracketAsync/flatMap(_:)``
  and `Array.sequence()` still release inner-then-outer / right-to-left.
- **Everything is structured.** When `await bracket { … }` returns, cleanup
  has finished. No work is left running in the background.
- **Dispose runs in the cancelled task.** `Task.isCancelled` is `true` inside
  dispose, so any cancellation-aware work it awaits fails immediately.

This matches how `defer` behaves in async Swift code. Most cleanups are
unaffected; the patterns below cover the ones that are.

## Which dispose callbacks are affected

| Dispose does…                                   | Under cancellation |
| ----------------------------------------------- | ------------------ |
| Synchronous work (`close(fd)`, unlock, free)    | ✅ Works           |
| Calls into an actor (`await pool.checkIn(c)`)   | ✅ Works           |
| Cancellation-aware async work (network, sleep)  | ❌ Fails early     |

If your dispose only falls into the first two rows, there is nothing to do.

## Pattern: fast path when cancelled

The usual answer is a cheaper cleanup when the task is cancelled. A cancelled
caller wants to stop, so an abrupt but complete cleanup beats a graceful one
that never finishes:

```swift
let withConnection = BracketAsync<Connection, DBError>(
    acquire: { await Connection.open(url) },
    dispose: { conn in
        if Task.isCancelled {
            conn.abort()                    // sync: drops the socket, no round trip
            return .success(())
        }
        return await conn.closeGracefully() // async: sends goodbye, waits for ack
    }
)
```

## Pattern: cleanup that must complete

Sometimes the async cleanup has to happen no matter what: rolling back a
remote transaction, releasing a distributed lock, flushing a write buffer.
Use ``BracketAsync/init(acquire:uncancellableDispose:)``:

```swift
let withTransaction = BracketAsync<Transaction, DBError>(
    acquire: { await db.begin() },
    uncancellableDispose: { tx in await tx.rollbackIfOpen() }
)
```

`uncancellableDispose` runs in a fresh unstructured `Task`, which doesn't inherit
the caller's cancellation, so `Task.isCancelled` is `false` inside it. The
bracket still awaits it, so the cleanup has finished by the time
`await bracket { … }` returns.

Trade-offs to keep in mind:

- The resource and error types must be `Sendable`, and `uncancellableDispose`
  must be a `@Sendable` closure.
- The uncancellable work can't be stopped, so a hang inside it blocks the
  caller. If the cleanup talks to something that can stall, give it a
  timeout of its own.
- This applies per bracket. In a ``BracketAsync/flatMap(_:)`` chain or
  `Array.sequence()`, only the brackets built with `uncancellableDispose`
  escape cancellation; the others still run their dispose in the cancelled
  task.

To make only part of a dispose uncancellable, the same trick works by hand:
wrap that part in `await Task { … }.value` inside a regular `dispose`.

## Throwing disposes

With ``BracketAsync/throwing(acquire:dispose:)``, a dispose that hits
cancellation usually *throws* `CancellationError`. Because a dispose failure
wins over the body's outcome, that `CancellationError` becomes the bracket's
result, even when the body succeeded. The same patterns apply:

```swift
let withSession = BracketAsync.throwing(
    acquire: { try await client.openSession() },
    dispose: { session in
        if Task.isCancelled {
            session.abort()                           // fast path
        } else {
            try await session.close()
        }
    }
)

// Or, when the close must complete (session must be Sendable):
dispose: { session in try await Task { try await session.close() }.value }
```

## Pattern: reacting to cancellation in the body

The body decides what cancellation means for the result. Check for it at
natural boundaries and return a failure. Dispose runs afterwards either way:

```swift
let imported = await withConnection { conn in
    for batch in batches {
        if Task.isCancelled { return .failure(.cancelled) }
        if case .failure(let error) = await conn.insert(batch) {
            return .failure(error)
        }
    }
    return .success(batches.count)
}
```

With `Error` as the bracket's error type, a `CancellationError` thrown by the
body's own calls flows through as an ordinary failure. Avoid swallowing it,
for example by retrying in a loop. The caller asked to stop.

## Acquire must clean up after itself

Dispose is only called after acquire **succeeds**. If acquire is cancelled
partway through and returns a failure, the bracket has no resource to
release. Anything acquire had already set up is acquire's job to undo before
returning:

```swift
acquire: {
    let socket = Socket()
    if case .failure(let error) = await socket.connect(host) {
        socket.close()       // undo the partial setup ourselves
        return .failure(error)
    }
    return .success(socket)
}
```

## Child tasks and fromTask

Child tasks created with `async let` or task groups inside your callbacks
are structured, so they are cancelled along with the caller.

``BracketAsync/fromTask(_:)->BracketAsync<R,E>`` and its overloads create an
unstructured task and **forward cancellation** to it: if the caller is
cancelled, so is the task. The throwing overload then fails with
`CancellationError`.

If you capture one shared, already-running task, such as
`fromTask { sharedTask }`, cancelling **any** caller cancels it for **every**
caller. If the shared work should outlive individual callers, use
``BracketAsync/fromAcquire(_:)`` with `await sharedTask.value` instead, which
doesn't forward cancellation.

## Testing cancellation

To make cancellation land at a known point, let the body or acquire signal
that it has started, then cancel. `started` here is a small one-shot signal,
an actor holding a `CheckedContinuation`:

```swift
let task = Task {
    await withConnection { conn in
        await started.fire()                // tell the test we're inside
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return .failure(.cancelled)
    }
}

await started.wait()
task.cancel()
let result = await task.value               // dispose has already run here
```

The package's own `BracketAsyncCancellationTests` use this approach.
