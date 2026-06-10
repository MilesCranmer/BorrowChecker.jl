# E15: Cache growth is unbounded across worlds
println("Julia: ", VERSION)
import BorrowChecker
function cachesizes()
    a = Base.@lock BorrowChecker.Auto.CHECKED_CACHE length(BorrowChecker.Auto.CHECKED_CACHE[])
    s = Base.@lock BorrowChecker.Auto.SUMMARY_STATE begin
        st = BorrowChecker.Auto.SUMMARY_STATE[]
        length(st.summary_cache) + length(st.tt_summary_cache)
    end
    (checked=a, summaries=s)
end
GC.gc(); h0 = Base.gc_live_bytes()
println("E15 start: ", cachesizes(), "  heap=", h0 ÷ 2^20, "MB")
heaps = Int[]
for round in 1:5
    for i in 1:200
        fname = Symbol("grow_", round, "_", i)
        Core.eval(Main, :(BorrowChecker.@safe $fname() = sum(push!(Int[], 1))))
        Base.invokelatest(getfield(Main, fname))
    end
    GC.gc()
    h = Base.gc_live_bytes()
    push!(heaps, h)
    println("E15 round $round: ", cachesizes(), "  heap=", h ÷ 2^20, "MB (+", (h - h0) ÷ 2^20, "MB)")
end
println("E15 MB per 1000 checks (linear est over rounds 2-5): ",
        round((heaps[end] - heaps[2]) / 3 / 200 * 1000 / 2^20; digits=1), "MB")

# Isolate the cache-attributable share: most heap growth is compiled code for the
# 1000 newly defined functions, not the caches themselves.
Base.@lock BorrowChecker.Auto.SUMMARY_STATE begin
    st = BorrowChecker.Auto.SUMMARY_STATE[]
    empty!(st.summary_cache); empty!(st.tt_summary_cache)
end
Base.@lock BorrowChecker.Auto.CHECKED_CACHE empty!(BorrowChecker.Auto.CHECKED_CACHE[])
GC.gc(); GC.gc()
h2 = Base.gc_live_bytes()
println("E15 after clearing caches: heap=", h2 ÷ 2^20, "MB  => cache-attributable: ",
        (heaps[end] - h2) ÷ 2^20, "MB per 1000 checks")
