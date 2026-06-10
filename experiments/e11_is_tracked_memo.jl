# E11: is_tracked_type memoization payoff. Run with --project=/tmp/patchenv.
println("Julia: ", VERSION)
import BorrowChecker
using BenchmarkTools
const Auto = BorrowChecker.Auto

struct Deep11a; x::Vector{Int}; y::Dict{Symbol,Vector{Float64}}; end
struct Deep11b; a::Deep11a; b::NTuple{4,Deep11a}; end
print("is_tracked_type(Deep11b): ")
@btime BorrowChecker.Auto.is_tracked_type(Deep11b)

# Count calls during one real first-check (E8-style function)
inner11(x) = (push!(x, 1); sum(x))
BorrowChecker.@safe function f11()
    x = collect(1:50)
    inner11(x)
end
Auto.BC_N_TRACKED[] = 0; Auto.BC_N_OWNED[] = 0
Auto.BC_LOG_ARGS[] = true
empty!(Auto.BC_TRACKED_ARGS)
t = @elapsed f11()
Auto.BC_LOG_ARGS[] = false
args = copy(Auto.BC_TRACKED_ARGS)
ntracked = Auto.BC_N_TRACKED[]; nowned = Auto.BC_N_OWNED[]
uniq = length(unique(map(objectid, args)))
println("E11 (E8-style first check): wall=$(t)s is_tracked_type calls=$ntracked is_owned_type calls=$nowned")
println("    logged args=$(length(args)) unique=$(uniq) repeat ratio=$(round(length(args)/max(uniq,1); digits=2))x")
using Printf
cnt = Dict{Any,Int}()
for a in args; cnt[a] = get(cnt, a, 0) + 1; end
println("    top repeated type args:")
for (k, v) in sort(collect(cnt); by=last, rev=true)[1:min(end, 10)]
    @printf("      %6d  %s\n", v, first(string(k), 80))
end

# Bigger workload: E10-style 500-statement function
body = [:(push!(x, $i)) for i in 1:500]
Core.eval(Main, quote
    BorrowChecker.@safe function big11()
        x = Int[]
        $(body...)
        return x
    end
end)
Auto.BC_N_TRACKED[] = 0; Auto.BC_N_OWNED[] = 0; Auto.BC_N_KNOWN[] = 0
Auto.BC_LOG_ARGS[] = true
empty!(Auto.BC_TRACKED_ARGS)
t2 = @elapsed try Base.invokelatest(big11) catch end
Auto.BC_LOG_ARGS[] = false
args2 = copy(Auto.BC_TRACKED_ARGS)
uniq2 = length(unique(map(objectid, args2)))
println("E11 (E10-style 500-stmt first check): wall=$(t2)s is_tracked=$(Auto.BC_N_TRACKED[]) is_owned=$(Auto.BC_N_OWNED[]) known_effects_get=$(Auto.BC_N_KNOWN[])")
println("    logged args=$(length(args2)) unique=$uniq2 repeat ratio=$(round(length(args2)/max(uniq2,1); digits=2))x")
