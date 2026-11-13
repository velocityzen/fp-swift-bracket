// Hegel runs on macOS and Linux only; see Package.swift.
#if os(macOS) || os(Linux)

    import FPBracket

    // Do-notation chains of 1 to 24 steps for Bracket, each a `bind` or a `let`.
    // Past 10 values the flattening overloads stop and the chain nests. Each
    // arity is its own overload, so every step is written out; the chain is
    // built one step at a time and ends with a `map` to one `Int`. Written by
    // the same pattern as DoChainsAsync.swift: keep the two in step.

    /// The longest chain the functions below build.
    let maxDoSteps = 24

    /// The chain after six values.
    typealias Six = (Int, Int, Int, Int, Int, Int)
    /// The most values the overloads flatten.
    typealias Ten = (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int)
    /// Past ten values each step nests the tuple: the chain after twelve
    /// values, and after eighteen.
    typealias Twelve = ((Ten, Int), Int)
    typealias Eighteen = ((((((Twelve, Int), Int), Int), Int), Int), Int)

    /// The values of a chain of ten, twelve and eighteen, in order.
    func ten(_ t: Ten) -> [Int] { [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9] }
    func twelve(_ t: Twelve) -> [Int] { ten(t.0.0) + [t.0.1, t.1] }
    func eighteen(_ t: Eighteen) -> [Int] {
        twelve(t.0.0.0.0.0.0) + [t.0.0.0.0.0.1, t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1]
    }

    /// `BracketDo` with `steps`, mapped to one `Int`.
    func doChain(_ steps: [DoStep], log: Log) -> Bracket<Int, Code> {
        precondition((1...maxDoSteps).contains(steps.count))
        return DoChain(steps: steps, log: log).steps1to6()
    }

    /// One chain's steps, and the log their brackets write to.
    struct DoChain: Sendable {
        let steps: [DoStep]
        let log: Log

        /// Step `k`'s bracket, offset by every value before it.
        func bracketAt(_ k: Int, _ values: [Int]) -> Bracket<Int, Code> {
            bracket(steps[k].expr!, offset: combined(values), log: log)
        }

        /// Step `k`'s value, offset by every value before it.
        func constantAt(_ k: Int, _ values: [Int]) -> Int {
            combined(values) &+ steps[k].constant!
        }
    }

    extension DoChain {
        /// Steps 1 to 6.
        func steps1to6() -> Bracket<Int, Code> {
            let s0: Bracket<Int, Code> =
                switch steps[0] {
                    case .bind(let e):
                        BracketDo<Code>().bind { bracket(e, offset: combined([]), log: log) }
                    case .let(let k): BracketDo<Code>().let { combined([]) &+ k }
                }
            guard steps.count > 1 else { return s0.map { a0 in combined([a0]) } }
            let s1 =
                steps[1].isBind
                ? s0.bind { a0 in bracketAt(1, [a0]) }
                : s0.let { a0 in constantAt(1, [a0]) }
            guard steps.count > 2 else { return s1.map { a0, a1 in combined([a0, a1]) } }
            let s2 =
                steps[2].isBind
                ? s1.bind { a0, a1 in bracketAt(2, [a0, a1]) }
                : s1.let { a0, a1 in constantAt(2, [a0, a1]) }
            guard steps.count > 3 else { return s2.map { a0, a1, a2 in combined([a0, a1, a2]) } }
            let s3 =
                steps[3].isBind
                ? s2.bind { a0, a1, a2 in bracketAt(3, [a0, a1, a2]) }
                : s2.let { a0, a1, a2 in constantAt(3, [a0, a1, a2]) }
            guard steps.count > 4 else {
                return s3.map { a0, a1, a2, a3 in combined([a0, a1, a2, a3]) }
            }
            let s4 =
                steps[4].isBind
                ? s3.bind { a0, a1, a2, a3 in bracketAt(4, [a0, a1, a2, a3]) }
                : s3.let { a0, a1, a2, a3 in constantAt(4, [a0, a1, a2, a3]) }
            guard steps.count > 5 else {
                return s4.map { a0, a1, a2, a3, a4 in combined([a0, a1, a2, a3, a4]) }
            }
            let s5 =
                steps[5].isBind
                ? s4.bind { a0, a1, a2, a3, a4 in bracketAt(5, [a0, a1, a2, a3, a4]) }
                : s4.let { a0, a1, a2, a3, a4 in constantAt(5, [a0, a1, a2, a3, a4]) }
            guard steps.count > 6 else {
                return s5.map { a0, a1, a2, a3, a4, a5 in combined([a0, a1, a2, a3, a4, a5]) }
            }
            return steps7to12(s5)
        }
    }

    extension DoChain {
        /// Steps 7 to 12.
        func steps7to12(_ s5: Bracket<Six, Code>) -> Bracket<Int, Code> {
            let s6 =
                steps[6].isBind
                ? s5.bind { a0, a1, a2, a3, a4, a5 in bracketAt(6, [a0, a1, a2, a3, a4, a5]) }
                : s5.let { a0, a1, a2, a3, a4, a5 in constantAt(6, [a0, a1, a2, a3, a4, a5]) }
            guard steps.count > 7 else {
                return s6.map { a0, a1, a2, a3, a4, a5, a6 in
                    combined([a0, a1, a2, a3, a4, a5, a6])
                }
            }
            let s7 =
                steps[7].isBind
                ? s6.bind { a0, a1, a2, a3, a4, a5, a6 in
                    bracketAt(7, [a0, a1, a2, a3, a4, a5, a6])
                }
                : s6.let { a0, a1, a2, a3, a4, a5, a6 in
                    constantAt(7, [a0, a1, a2, a3, a4, a5, a6])
                }
            guard steps.count > 8 else {
                return s7.map { a0, a1, a2, a3, a4, a5, a6, a7 in
                    combined([a0, a1, a2, a3, a4, a5, a6, a7])
                }
            }
            let s8 =
                steps[8].isBind
                ? s7.bind { a0, a1, a2, a3, a4, a5, a6, a7 in
                    bracketAt(8, [a0, a1, a2, a3, a4, a5, a6, a7])
                }
                : s7.let { a0, a1, a2, a3, a4, a5, a6, a7 in
                    constantAt(8, [a0, a1, a2, a3, a4, a5, a6, a7])
                }
            guard steps.count > 9 else {
                return s8.map { a0, a1, a2, a3, a4, a5, a6, a7, a8 in
                    combined([a0, a1, a2, a3, a4, a5, a6, a7, a8])
                }
            }
            let s9 =
                steps[9].isBind
                ? s8.bind { a0, a1, a2, a3, a4, a5, a6, a7, a8 in
                    bracketAt(9, [a0, a1, a2, a3, a4, a5, a6, a7, a8])
                }
                : s8.let { a0, a1, a2, a3, a4, a5, a6, a7, a8 in
                    constantAt(9, [a0, a1, a2, a3, a4, a5, a6, a7, a8])
                }
            guard steps.count > 10 else {
                return s9.map { a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 in
                    combined([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9])
                }
            }
            let s10 =
                steps[10].isBind
                ? s9.bind { t in bracketAt(10, ten(t)) }
                : s9.let { t in constantAt(10, ten(t)) }
            guard steps.count > 11 else { return s10.map { t in combined(ten(t.0) + [t.1]) } }
            let s11 =
                steps[11].isBind
                ? s10.bind { t in bracketAt(11, ten(t.0) + [t.1]) }
                : s10.let { t in constantAt(11, ten(t.0) + [t.1]) }
            guard steps.count > 12 else { return s11.map { t in combined(twelve(t)) } }
            return steps13to18(s11)
        }
    }

    extension DoChain {
        /// Steps 13 to 18.
        func steps13to18(_ s11: Bracket<Twelve, Code>) -> Bracket<Int, Code> {
            let s12 =
                steps[12].isBind
                ? s11.bind { t in bracketAt(12, twelve(t)) }
                : s11.let { t in constantAt(12, twelve(t)) }
            guard steps.count > 13 else { return s12.map { t in combined(twelve(t.0) + [t.1]) } }
            let s13 =
                steps[13].isBind
                ? s12.bind { t in bracketAt(13, twelve(t.0) + [t.1]) }
                : s12.let { t in constantAt(13, twelve(t.0) + [t.1]) }
            guard steps.count > 14 else {
                return s13.map { t in combined(twelve(t.0.0) + [t.0.1, t.1]) }
            }
            let s14 =
                steps[14].isBind
                ? s13.bind { t in bracketAt(14, twelve(t.0.0) + [t.0.1, t.1]) }
                : s13.let { t in constantAt(14, twelve(t.0.0) + [t.0.1, t.1]) }
            guard steps.count > 15 else {
                return s14.map { t in combined(twelve(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
            }
            let s15 =
                steps[15].isBind
                ? s14.bind { t in bracketAt(15, twelve(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
                : s14.let { t in constantAt(15, twelve(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
            guard steps.count > 16 else {
                return s15.map { t in
                    combined(twelve(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            }
            let s16 =
                steps[16].isBind
                ? s15.bind { t in
                    bracketAt(16, twelve(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
                : s15.let { t in
                    constantAt(16, twelve(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            guard steps.count > 17 else {
                return s16.map { t in
                    combined(twelve(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            }
            let s17 =
                steps[17].isBind
                ? s16.bind { t in
                    bracketAt(
                        17,
                        twelve(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1]
                    )
                }
                : s16.let { t in
                    constantAt(
                        17,
                        twelve(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1]
                    )
                }
            guard steps.count > 18 else { return s17.map { t in combined(eighteen(t)) } }
            return steps19to24(s17)
        }
    }

    extension DoChain {
        /// Steps 19 to 24.
        func steps19to24(_ s17: Bracket<Eighteen, Code>) -> Bracket<Int, Code> {
            let s18 =
                steps[18].isBind
                ? s17.bind { t in bracketAt(18, eighteen(t)) }
                : s17.let { t in constantAt(18, eighteen(t)) }
            guard steps.count > 19 else { return s18.map { t in combined(eighteen(t.0) + [t.1]) } }
            let s19 =
                steps[19].isBind
                ? s18.bind { t in bracketAt(19, eighteen(t.0) + [t.1]) }
                : s18.let { t in constantAt(19, eighteen(t.0) + [t.1]) }
            guard steps.count > 20 else {
                return s19.map { t in combined(eighteen(t.0.0) + [t.0.1, t.1]) }
            }
            let s20 =
                steps[20].isBind
                ? s19.bind { t in bracketAt(20, eighteen(t.0.0) + [t.0.1, t.1]) }
                : s19.let { t in constantAt(20, eighteen(t.0.0) + [t.0.1, t.1]) }
            guard steps.count > 21 else {
                return s20.map { t in combined(eighteen(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
            }
            let s21 =
                steps[21].isBind
                ? s20.bind { t in bracketAt(21, eighteen(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
                : s20.let { t in constantAt(21, eighteen(t.0.0.0) + [t.0.0.1, t.0.1, t.1]) }
            guard steps.count > 22 else {
                return s21.map { t in
                    combined(eighteen(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            }
            let s22 =
                steps[22].isBind
                ? s21.bind { t in
                    bracketAt(22, eighteen(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
                : s21.let { t in
                    constantAt(22, eighteen(t.0.0.0.0) + [t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            guard steps.count > 23 else {
                return s22.map { t in
                    combined(eighteen(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1])
                }
            }
            let s23 =
                steps[23].isBind
                ? s22.bind { t in
                    bracketAt(
                        23,
                        eighteen(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1]
                    )
                }
                : s22.let { t in
                    constantAt(
                        23,
                        eighteen(t.0.0.0.0.0) + [t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1]
                    )
                }
            return s23.map { t in
                combined(
                    eighteen(t.0.0.0.0.0.0) + [
                        t.0.0.0.0.0.1, t.0.0.0.0.1, t.0.0.0.1, t.0.0.1, t.0.1, t.1,
                    ]
                )
            }
        }
    }

#endif
