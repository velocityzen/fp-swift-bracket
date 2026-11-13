import FPBracket

// The real brackets for an `Expr`, logging what they do the way the model does.

// MARK: - Bracket

func bracket(_ e: Expr, offset: Int = 0, log: Log) -> Bracket<Int, Code> {
    switch e {
        case .leaf(let id, let acquire, let dispose, _):
            return Bracket(
                acquire: {
                    log.add("acquire \(id)")
                    return acquire.value(id &+ offset)
                },
                dispose: { value in
                    log.dispose("dispose \(id) \(value)", kind: .plain)
                    return dispose.void
                }
            )
        case .of(let x):
            return .of(x)
        case .fromAcquire(let id, let acquire, _):
            return .fromAcquire {
                log.add("acquire \(id)")
                return acquire.value(id &+ offset)
            }
        case .map(let e, let k):
            return bracket(e, offset: offset, log: log).map { $0 &+ k }
        case .mapError(let e, let k):
            return bracket(e, offset: offset, log: log).mapError { Code(code: $0.code &+ k) }
        case .flatMap(let outer, let inner):
            return bracket(outer, offset: offset, log: log).flatMap { o in
                bracket(inner, offset: o, log: log)
            }
        case .tap(let outer, let inner):
            return bracket(outer, offset: offset, log: log).tap { o in
                bracket(inner, offset: o, log: log)
            }
        case .bind(let outer, let inner):
            return bracket(outer, offset: offset, log: log)
                .bind { o in bracket(inner, offset: o, log: log) }
                .map { pair($0, $1) }
        case .sequence(let es, let traverse):
            let all: Bracket<[Int], Code> =
                traverse
                ? es.traverse { bracket($0, offset: offset, log: log) }
                : es.map { bracket($0, offset: offset, log: log) }.sequence()
            return all.map(combined)
        case .constant(let e, let k):
            return bracket(e, offset: offset, log: log).as(k)
        case .unit(let e):
            return bracket(e, offset: offset, log: log).asUnit().map { 0 }
    }
}

/// Calls the bracket with a body that logs the resource and returns `result`.
func call(_ b: Bracket<Int, Code>, body result: Result<Int, Code>, log: Log) -> Result<Int, Code> {
    b { value in
        log.add("body \(value)")
        return result
    }
}

// MARK: - BracketAsync

func bracketAsync(_ e: Expr, offset: Int = 0, log: Log) -> BracketAsync<Int, Code> {
    switch e {
        case .leaf(let id, let acquire, let dispose, let kind):
            let acquireValue: () async -> Result<Int, Code> = {
                await Task.yield()
                log.add("acquire \(id)")
                return acquire.value(id &+ offset)
            }
            switch kind {
                case .plain:
                    return BracketAsync(
                        acquire: acquireValue,
                        dispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .plain)
                            return dispose.void
                        }
                    )
                case .uncancellable:
                    return BracketAsync(
                        acquire: acquireValue,
                        uncancellableDispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .uncancellable)
                            return dispose.void
                        }
                    )
                case .throwing:
                    return BracketAsync<Int, any Error>.throwing(
                        acquire: {
                            await Task.yield()
                            log.add("acquire \(id)")
                            return try acquire.value(id &+ offset).get()
                        },
                        dispose: { value in
                            await Task.yield()
                            log.dispose("dispose \(id) \(value)", kind: .throwing)
                            try dispose.void.get()
                        }
                    ).mapError { $0 as! Code }
            }
        case .of(let x):
            return .of(x)
        case .fromAcquire(let id, let acquire, let viaTask):
            if viaTask {
                return .fromTask {
                    Task {
                        log.add("acquire \(id)")
                        return acquire.value(id &+ offset)
                    }
                }
            }
            return .fromAcquire {
                await Task.yield()
                log.add("acquire \(id)")
                return acquire.value(id &+ offset)
            }
        case .map(let e, let k):
            return bracketAsync(e, offset: offset, log: log).map { $0 &+ k }
        case .mapError(let e, let k):
            return bracketAsync(e, offset: offset, log: log).mapError { Code(code: $0.code &+ k) }
        case .flatMap(let outer, let inner):
            return bracketAsync(outer, offset: offset, log: log).flatMap { o in
                bracketAsync(inner, offset: o, log: log)
            }
        case .tap(let outer, let inner):
            return bracketAsync(outer, offset: offset, log: log).tap { o in
                bracketAsync(inner, offset: o, log: log)
            }
        case .bind(let outer, let inner):
            return bracketAsync(outer, offset: offset, log: log)
                .bind { o in bracketAsync(inner, offset: o, log: log) }
                .map { pair($0, $1) }
        case .sequence(let es, let traverse):
            let all: BracketAsync<[Int], Code> =
                traverse
                ? es.traverse { bracketAsync($0, offset: offset, log: log) }
                : es.map { bracketAsync($0, offset: offset, log: log) }.sequence()
            return all.map(combined)
        case .constant(let e, let k):
            return bracketAsync(e, offset: offset, log: log).as(k)
        case .unit(let e):
            return bracketAsync(e, offset: offset, log: log).asUnit().map { 0 }
    }
}

/// Calls the async bracket with a body that logs the resource, suspends,
/// and returns `result`.
func call(
    _ b: BracketAsync<Int, Code>,
    body result: Result<Int, Code>,
    log: Log
) async -> Result<Int, Code> {
    await b { value in
        log.add("body \(value)")
        await Task.yield()
        return result
    }
}
