# E14: Lock acquire per _known_effects_get in the hot path.
# Run under default project (timing) AND --project=/tmp/patchenv (call counting in e11 script).
println("Julia: ", VERSION, "  threads: ", Threads.nthreads())
import BorrowChecker, BenchmarkTools
using BenchmarkTools
BorrowChecker.Auto._ensure_registry_initialized()
print("_known_effects_get(push!): ")
@btime BorrowChecker.Auto._known_effects_get(push!)

# Aggregate throughput: first-checks of 8 distinct generated functions, 1 vs N threads
function gen_fns(tag, n)
    fs = Function[]
    for i in 1:n
        fname = Symbol("e14_", tag, "_", i)
        iname = Symbol("e14i_", tag, "_", i)
        # (sort! degrades to unknown-call => false positive; use a clean chain)
        i2name = Symbol("e14i2_", tag, "_", i)
        Core.eval(Main, quote
            $i2name(x) = (push!(x, 2); nothing)
            function $iname(x)
                $i2name(x)
                x[1] = 3
                return nothing
            end
            BorrowChecker.@safe function $fname()
                x = collect(1:100)
                $iname(x)
                return sum(x)
            end
        end)
        push!(fs, getfield(Main, fname))
    end
    fs
end

# Warm up checker infrastructure once so seq/par batches are comparable
warmf = gen_fns("warm", 1)
Base.invokelatest(warmf[1])

fs1 = gen_fns("seq", 8)
t_seq = @elapsed for f in fs1
    Base.invokelatest(f)
end
println("E14 sequential first-check of 8 distinct fns: $(t_seq)s")

fs2 = gen_fns("par", 8)
t_par = @elapsed begin
    ts = [Threads.@spawn Base.invokelatest($f) for f in fs2]
    foreach(wait, ts)
end
println("E14 parallel ($(Threads.nthreads()) threads) first-check of 8 distinct fns: $(t_par)s  speedup=", round(t_seq / t_par; digits=2), "x")
