# E7: Summary-cache race (assert + cross-task budget conflation). Run with -t 8 and -t 1.
#
# NOTE: the originally-suggested inner `(push!(x,1); sort!(x); nothing)` is a false
# positive even single-threaded (`sort!` fails to summarize => unknown call =>
# consume-all). We use a two-level chain that passes cleanly at -t 1, so any error
# under -t 8 is threading-induced.
println("Julia: ", VERSION, "  threads: ", Threads.nthreads())
import BorrowChecker
errs = Threads.Atomic{Int}(0); asserts = Threads.Atomic{Int}(0)
example_err = Ref{Any}(nothing)
for trial in 1:100
    fname = Symbol("race_f_", trial)
    Core.eval(Main, quote
        $(Symbol("race_inner2_", trial))(x) = (push!(x, 2); nothing)
        function $(Symbol("race_inner_", trial))(x)
            $(Symbol("race_inner2_", trial))(x)
            x[1] = 3
            return nothing
        end
        BorrowChecker.@safe function $fname()
            x = collect(1:100)
            $(Symbol("race_inner_", trial))(x)
            return sum(x)
        end
    end)
    f = getfield(Main, fname)
    tasks = [Threads.@spawn try Base.invokelatest($f); nothing catch e; e end for _ in 1:8]
    rs = fetch.(tasks)
    for r in rs
        r === nothing && continue
        if r isa AssertionError
            Threads.atomic_add!(asserts, 1)
        else
            Threads.atomic_add!(errs, 1)
        end
        example_err[] === nothing && (example_err[] = r)
    end
end
println("E7: assertion errors = ", asserts[], ", other errors = ", errs[],
        "  (any AssertionError => race CONFIRMED; nonzero spurious BorrowCheckErrors only under threading => conflation CONFIRMED)")
example_err[] !== nothing && println("example error: ", typeof(example_err[]), ": ", first(sprint(showerror, example_err[]), 500))
