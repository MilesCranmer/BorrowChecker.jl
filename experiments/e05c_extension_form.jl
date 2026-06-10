# E5c: user-facing cache poisoning via the method-extension form.
#
# Module MX contains a violating g(). Module A defines, via the extension form
# `@safe scope=:module function MX.helper() ... end`, a method whose tt lives in
# MX but whose root_module is A (the macro's calling module). Checking helper
# under root=A passes (g out of scope) and caches Tuple{typeof(MX.helper)} with a
# sig that omits the root. A @safe wrapper defined *in* MX that calls helper then
# recurses into the same tt under root=MX -- and hits the stale "passed" entry.
println("Julia: ", VERSION)
import BorrowChecker
const Auto = BorrowChecker.Auto

module MX
    const CACHE = Dict{Int,Vector{Int}}()
    g() = (x = [1, 2]; CACHE[1] = x; push!(x, 3); x)   # violation
    function helper end
end

module A
    import BorrowChecker
    import ..MX
    # extension form: tt module is MX, root_module is A
    BorrowChecker.@safe scope = :module function MX.helper()
        MX.g()
        return nothing
    end
end

module MXWrap end
Core.eval(MX, :(import BorrowChecker))
Core.eval(MX, :(BorrowChecker.@safe scope = :module wrapper() = (helper(); nothing)))

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
    # Control: wrapper with cold caches must FAIL (helper -> g, all in MX scope)
    clearall!()
    rw_fresh = run(MX.wrapper)
    println("E5c control: MX.wrapper fresh = ", rw_fresh, "  (expect :failed; else experiment invalid)")

    # Probe: helper via extension-form @safe (root=A) first -- expect pass
    clearall!()
    rh = run(MX.helper)
    println("E5c MX.helper (root=A via extension form) = ", rh, "  (expect :passed)")
    rw = run(MX.wrapper)
    println("E5c MX.wrapper after helper = ", rw,
            "  (:passed => user-facing poisoning CONFIRMED, :failed => not reproduced)")
end
main()
