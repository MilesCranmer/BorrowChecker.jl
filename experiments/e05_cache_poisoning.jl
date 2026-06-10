# E5: scope=:module cache poisoning (root_module excluded from cache key)
#
# NOTES vs the original protocol:
# 1. The originally-suggested violation (y = x; push!(x, 3); return y) is NOT
#    detectable inside an uninstrumented callee: without @safe's __bc_bind__ the
#    alias collapses to one SSA value in lowered IR. We use a Dict-escape
#    violation instead, which a fresh recursive check rooted at M5 does find.
# 2. On Julia 1.12, every new toplevel global binding bumps the world counter
#    (world-partitioned bindings), and CHECKED_CACHE requires an exact world
#    match. A naive toplevel script therefore accidentally misses the cache
#    between probes. Real call sites live inside functions where the world is
#    stable between calls, so we run the probe sequence inside a function (one
#    world) -- this is the representative scenario.
println("Julia: ", VERSION)
import BorrowChecker
const Auto = BorrowChecker.Auto

module M5
    const CACHE = Dict{Int,Vector{Int}}()
    g() = (x = [1, 2]; CACHE[1] = x; push!(x, 3); x)   # escape-then-mutate violation inside g
    helper() = (g(); nothing)                           # helper itself is clean
end
module Other5 end

clear!() = begin
    Base.@lock Auto.CHECKED_CACHE empty!(Auto.CHECKED_CACHE[])
    empty!(Auto.PER_TASK_CHECKED_CACHE[])
end

const tt = Tuple{typeof(M5.helper)}

check(root) = try
    Auto.__bc_assert_safe__(tt; cfg=Auto.Config(scope=:module, root_module=root))
    :passed
catch e
    :failed
end

function main()
    # Baseline 1: fresh check rooted at M5 must FAIL
    clear!()
    r1 = check(M5)
    println("E5 baseline (root=M5, fresh): ", r1, "  (expect :failed; if :passed the experiment is invalid)")

    # Baseline 2: fresh check rooted at Other5 should PASS (g out of scope)
    clear!()
    r2 = check(Other5)
    println("E5 baseline (root=Other5, fresh): ", r2, "  (expect :passed)")

    # Bug probe: WITHOUT clearing, now check rooted at M5 (same world: we are
    # inside one function invocation, no new bindings/methods)
    r3 = check(M5)
    println("E5 probe (root=M5 after Other5): ", r3, "  (:passed => claim CONFIRMED, :failed => FALSIFIED)")

    # Control: fresh again
    clear!()
    r4 = check(M5)
    println("E5 control (root=M5, fresh again): ", r4, "  (expect :failed)")
end
main()
