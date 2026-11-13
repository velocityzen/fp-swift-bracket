// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import Foundation
    import HegelTesting

    // What the properties record with `tc.event`, and claim with
    // `property(reaching:)`: the states each property exists to test.

    enum Reach {
        static let bodyRan = "the body ran"
        static let deepBody = "the body ran after 10 or more acquires"
        static let rollback = "an acquire failed while holding a resource"
        static let releasesFailed = "two or more releases failed"
        static let innerBeatOuter = "an inner failure beat an outer release failure"
        static let releaseBeatFailingBody = "a release failure beat a failing body"
        static let releaseBeatSucceedingBody = "a release failure beat a succeeding body"
        static let directSequence = "sequence() of two or more acquire/dispose pairs"
        static let directRollback = "sequence() of pairs rolled back"
        static let resourceRollback = "sequence() of composed brackets rolled back"
        static let directReleasesFailed = "sequence() of pairs: two or more releases failed"
        static let resourceReleasesFailed =
            "sequence() of composed brackets: two or more releases failed"
        static let resourceSequence = "sequence() of a composed bracket"
        static let emptySequence = "sequence() of no brackets"
        static let composedMapErrorResource =
            "mapError of a composed bracket, acquired by sequence()"
        static let pastFlattening = "the body got more than 10 do-notation values"
        static let cancelledBeforeStart = "cancelled before the call started"
        static let cancelledHang = "a hang was cancelled"

        static func cancelledDispose(_ kind: LeafKind) -> String {
            "\(kind.label): a dispose ran after the call was cancelled"
        }

        static func hangCancelled(_ via: FromKind) -> String {
            "\(via.label): a hang was cancelled"
        }

        /// What every model-checked property claims.
        static let model = [
            bodyRan, deepBody, rollback, releasesFailed, innerBeatOuter,
            releaseBeatFailingBody, releaseBeatSucceedingBody,
            directSequence, resourceSequence, composedMapErrorResource,
        ]

        /// What the async model-checked property claims on top: every
        /// constructor, failing.
        static let constructors =
            LeafKind.allCases.flatMap {
                ["\($0.label): acquire failed", "\($0.label): release failed"]
            }
            + FromKind.failing.map { "\($0.label): failed" }
            + ["\(FromKind.neverTask.label): succeeded"]
    }

    /// Records what the model went through, and what `e` is built from.
    func recordReach(_ tc: TestCase, _ e: Expr?, _ log: ModelLog, constructors: Bool) throws {
        var labels = log.reached
        if constructors {
            labels.formUnion(log.constructors)
        }
        if log.bodyRan {
            labels.insert(Reach.bodyRan)
            if log.acquired >= 10 {
                labels.insert(Reach.deepBody)
            }
            // The body running after many acquires is rare: steer toward it.
            try tc.target(Double(log.acquired), label: "acquires before the body")
        }
        if log.releaseFailures >= 2 {
            labels.insert(Reach.releasesFailed)
        }
        if let e {
            structure(e, asResource: false, into: &labels)
        }
        for label in labels.sorted() {
            try tc.event(label)
        }
        try tc.event("acquires", value: Double(log.acquired))
    }

    /// Notes which of `sequence()`'s paths `e` takes. `asResource` is whether
    /// `e` is acquired by a `sequence()` of composed brackets, which acquires
    /// each one and holds on to its release rather than running its scope.
    func structure(_ e: Expr, asResource: Bool, into labels: inout Set<String>) {
        switch e {
            case .leaf, .of, .fromAcquire, .hang:
                return
            case .sequence(let es, _):
                let direct = es.allSatisfy(\.isDirect)
                if es.isEmpty {
                    labels.insert(Reach.emptySequence)
                } else if !direct {
                    labels.insert(Reach.resourceSequence)
                } else if es.count >= 2 {
                    labels.insert(Reach.directSequence)
                }
                for e in es {
                    structure(e, asResource: asResource || !direct, into: &labels)
                }
            case .mapError(let e, _):
                if asResource, !e.isDirect {
                    labels.insert(Reach.composedMapErrorResource)
                }
                structure(e, asResource: asResource, into: &labels)
            case .map(let e, _), .constant(let e, _), .unit(let e):
                structure(e, asResource: asResource, into: &labels)
            case .flatMap(let o, let i), .tap(let o, let i), .bind(let o, let i):
                structure(o, asResource: asResource, into: &labels)
                structure(i, asResource: asResource, into: &labels)
        }
    }

    /// `count` test cases, unless `HEGEL_TEST_CASES` asks for another
    /// number. A `.hegel(testCases:)` trait otherwise wins over the
    /// environment, which would keep a deep run at the per-test count.
    func testCases(_ count: Int) -> Int {
        ProcessInfo.processInfo.environment["HEGEL_TEST_CASES"].flatMap(Int.init) ?? count
    }

#endif
