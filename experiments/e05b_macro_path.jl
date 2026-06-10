# E5b: user-facing macro path for scope=:module cache poisoning.
#
# The outer tt always differs between two @safe wrappers (different functions), so
# masking via the user-facing API must travel through the *callee* caches shared by
# the recursive check. Setup: both wrappers call a shared uninstrumented
# intermediate Mid5.mid() -> Shared5.g() (g contains the violation).
#   - ModC.helperC:    @safe scope=:module, defined in ModC    => g out of scope => should pass
#   - Shared5.helperS2: @safe scope=:module, defined in Shared5 => g in scope    => should fail
# All definitions happen at load time; calls happen later at a stable world,
# matching real usage.
println("Julia: ", VERSION)
import BorrowChecker
const Auto = BorrowChecker.Auto

module Shared5
    const CACHE = Dict{Int,Vector{Int}}()
    g() = (x = [1, 2]; CACHE[1] = x; push!(x, 3); x)   # escape-then-mutate violation inside g
end

module Mid5
    import ..Shared5
    mid() = (Shared5.g(); nothing)
end

module ModC
    import BorrowChecker
    import ..Mid5
    BorrowChecker.@safe scope = :module helperC() = (Mid5.mid(); nothing)
end

module Shared5Wrappers end
Core.eval(Shared5, :(import BorrowChecker))
Core.eval(Shared5, :(import ..Mid5))
Core.eval(Shared5, :(BorrowChecker.@safe scope = :module helperS2() = (Mid5.mid(); nothing)))

clearall!() = begin
    Base.@lock Auto.CHECKED_CACHE empty!(Auto.CHECKED_CACHE[])
    empty!(Auto.PER_TASK_CHECKED_CACHE[])
    Base.@lock Auto.SUMMARY_STATE begin
        st = Auto.SUMMARY_STATE[]
        empty!(st.summary_cache)
        empty!(st.tt_summary_cache)
    end
end

run(f) = try
    Base.invokelatest(f)
    :passed
catch e
    :failed
end

function main()
    # Fresh control first (order A): helperS2 with cold caches must FAIL
    clearall!()
    rS_fresh = run(Shared5.helperS2)
    println("E5b control: Shared5.helperS2 fresh = ", rS_fresh, "  (expect :failed; else experiment invalid)")

    # Order B: helperC first (passes, warms shared callee caches), then helperS2
    clearall!()
    rC = run(ModC.helperC)
    println("E5b ModC.helperC fresh = ", rC, "  (expect :passed)")
    rS = run(Shared5.helperS2)
    println("E5b Shared5.helperS2 after helperC = ", rS,
            "  (:passed => user-facing masking CONFIRMED, :failed => macro path unaffected)")
end
main()
