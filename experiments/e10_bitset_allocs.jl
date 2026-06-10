# E10: Allocation profile of check_ir (per-statement BitSet copies)
println("Julia: ", VERSION)
import BorrowChecker
body = [:(push!(x, $i)) for i in 1:500]
Core.eval(Main, quote
    BorrowChecker.@safe function big10()
        x = Int[]
        $(body...)
        return x
    end
end)
# Warm up checker infrastructure on a small function first, so the profile is
# dominated by the actual check of big10 rather than one-time compilation.
BorrowChecker.@safe warm10() = sum(push!(Int[], 1))
warm10()

# NOTE: sample_rate=1 over this check produces multi-GB profile data (OOMs a 4-core
# container). 0.05 still gives a stable ranking of allocation sites.
using Profile
t = @elapsed begin
    Profile.Allocs.@profile sample_rate = 0.05 try
        Base.invokelatest(big10)
    catch
    end
end
println("first-check+run wall time (under alloc profiling): $(t)s")
results = Profile.Allocs.fetch()
println("total alloc samples: ", length(results.allocs))
using Printf
counts = Dict{String,Int}()
nbytes = Dict{String,Int}()
function first_meaningful(st)
    for fr in st
        f = string(fr.file)
        occursin("gc-alloc-profiler", f) && continue
        occursin("alloc.c", f) && continue
        occursin(r"\.c$", f) && continue
        startswith(string(fr.func), "maybe_record_alloc") && continue
        return fr
    end
    return isempty(st) ? nothing : st[1]
end
for a in results.allocs
    fr = first_meaningful(a.stacktrace)
    fr === nothing && continue
    k = string(fr.file, ":", fr.line)
    counts[k] = get(counts, k, 0) + 1
    nbytes[k] = get(nbytes, k, 0) + a.size
end
println("--- top 15 by bytes ---")
for (k, v) in sort(collect(nbytes); by=last, rev=true)[1:min(end, 15)]
    @printf("%12d bytes  %8d allocs  %s\n", v, counts[k], k)
end
# Aggregate to checker.jl
ck_bytes = sum(v for (k, v) in nbytes if occursin("checker.jl", k); init=0)
tot_bytes = sum(values(nbytes); init=0)
println("checker.jl share of bytes (first frame): ", round(100 * ck_bytes / max(tot_bytes, 1); digits=1), "%")

# Fairer attribution: classify each sample by whole-stack ownership.
own = Dict{String,Int}()
ownbytes = Dict{String,Int}()
bc_lines = Dict{String,Int}()
for a in results.allocs
    cat = "other"
    bcline = nothing
    for fr in a.stacktrace
        f = string(fr.file)
        if occursin("BorrowChecker", f) || occursin("/src/auto/", f)
            cat = "BorrowChecker"
            bcline = string(basename(f), ":", fr.line)
            break
        elseif occursin("Compiler/src", f)
            cat = "Julia Compiler (inference)"
            break
        end
    end
    own[cat] = get(own, cat, 0) + 1
    ownbytes[cat] = get(ownbytes, cat, 0) + a.size
    if bcline !== nothing
        bc_lines[bcline] = get(bc_lines, bcline, 0) + a.size
    end
end
println("--- whole-stack attribution (bytes) ---")
totb = sum(values(ownbytes); init=1)
for (k, v) in sort(collect(ownbytes); by=last, rev=true)
    println("  ", k, ": ", v, " bytes (", round(100v / totb; digits=1), "%), ", own[k], " allocs")
end
println("--- top BorrowChecker lines by bytes ---")
for (k, v) in sort(collect(bc_lines); by=last, rev=true)[1:min(end, 10)]
    println("  ", v, "  ", k)
end
