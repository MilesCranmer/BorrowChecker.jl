# E8b: probe the opposite failure mode of edge-based invalidation -- does a
# violating redefinition of a callee re-trigger the check (no stale pass)?
println("Julia: ", VERSION)
import BorrowChecker
const CACHE = Dict{Int,Vector{Int}}()
inner(x) = (push!(x, 1); nothing)                  # clean
BorrowChecker.@safe scope = :user function f()
    x = collect(1:50)
    inner(x)
    return sum(x)
end
println("first call (clean inner): ", try f(); "ok" catch e; typeof(e) end)
inner(x) = (CACHE[1] = x; push!(x, 99); nothing)   # violating redefinition
println("after violating redefinition: ",
        try Base.invokelatest(f); "ok (STALE PASS => under-invalidation)"
        catch e; "$(typeof(e)) (re-checked correctly)" end)
