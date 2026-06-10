# E4: Unknown foreigncall treated as write-only, not escape
println("Julia: ", VERSION)
import BorrowChecker
const LIB = "/tmp/libstash.so"
BorrowChecker.@safe function f4()
    x = [1, 2, 3]
    ccall((:keep, LIB), Cvoid, (Any,), x)   # C side retains x
    push!(x, 4)                              # use after escape
    return x
end
println("E4: ", try f4(); "NO ERROR (claim CONFIRMED)" catch e; "threw (claim FALSIFIED?): $(typeof(e)): $(sprint(showerror, e))" end)

# Comparison: README-style Julia-level escape (Dict cache) -- should throw
const CACHE4 = Dict{Int,Vector{Int}}()
BorrowChecker.@safe function f4b()
    x = [1, 2, 3]
    CACHE4[1] = x          # Julia-level escape
    push!(x, 4)            # use after escape
    return x
end
println("E4b control (Julia-level escape): ", try f4b(); "NO ERROR (escape detection broken generally!)" catch e; "threw (control OK): $(typeof(e)): $(first(sprint(showerror, e), 300))" end)
