# E13: __bc_bind__ tax on the instrumented body (post-check)
println("Julia: ", VERSION)
import BorrowChecker, BenchmarkTools
using BenchmarkTools
using InteractiveUtils: code_llvm, code_typed
BorrowChecker.@safe function ksafe(v::Vector{Float64})
    s = 0.0
    a = v; b = a; c = b           # binding-heavy
    for i in eachindex(c)
        t = c[i]; u = t * t; s += u
    end
    return s
end
function kraw(v::Vector{Float64})
    s = 0.0
    a = v; b = a; c = b
    for i in eachindex(c); t = c[i]; u = t * t; s += u; end
    return s
end
v = rand(10_000); ksafe(v); kraw(v)
b1 = @benchmark ksafe($v)
b2 = @benchmark kraw($v)
println("E13 safe: min=", minimum(b1).time, "ns median=", BenchmarkTools.median(b1).time, "ns")
println("E13 raw:  min=", minimum(b2).time, "ns median=", BenchmarkTools.median(b2).time, "ns")
println("E13 slowdown(min) = ", minimum(b1).time / minimum(b2).time)

io = IOBuffer()
code_llvm(io, ksafe, Tuple{Vector{Float64}}; debuginfo=:none)
llvm = String(take!(io))
nbind = count("__bc_bind__", llvm)
nbarrier = count("inferencebarrier", llvm)
ncalls = count(r"\bcall\b", llvm)
println("E13 LLVM IR: __bc_bind__ mentions=", nbind, " inferencebarrier mentions=", nbarrier, " call instructions=", ncalls, " IR lines=", count('\n', llvm))

# Also inspect typed IR for bind/barrier remnants and check whether the macro
# inserts __bc_bind__ into the body at all.
ct = code_typed(ksafe, Tuple{Vector{Float64}})[1][1]
src = string(ct)
println("typed IR: __bc_bind__=", count("__bc_bind__", src), " inferencebarrier=", count("inferencebarrier", src), " statements=", length(ct.code))
ex = Meta.@lower 1 + 1  # placeholder
mex = string(macroexpand(Main, :(BorrowChecker.@safe function mx(v::Vector{Float64})
    a = v; b = a
    return sum(b)
end)))
println("macroexpansion contains __bc_bind__: ", occursin("__bc_bind__", mex))
