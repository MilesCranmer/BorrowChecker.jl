# E12: Cold-check latency and budget-driven false positives on realistic code
println("Julia: ", VERSION)
import BorrowChecker
cases = [
    :(function c1(d::Dict{String,Vector{Int}})
        ks = sort(collect(keys(d)))
        out = String[]
        for k in ks; push!(out, k * "=" * string(sum(d[k]))); end
        join(out, ",")
    end),
    :(function c2(v::Vector{Float64})
        s = sort(v; by=abs, rev=true)
        io = IOBuffer()
        for x in s; print(io, round(x; digits=3), ' '); end
        String(take!(io))
    end),
    :(function c3(n::Int)
        d = Dict{Int,Vector{Int}}()
        for i in 1:n; push!(get!(d, i % 7, Int[]), i); end
        sum(length, values(d))
    end),
]
for (i, ex) in enumerate(cases)
    f = Core.eval(Main, :(BorrowChecker.@safe $ex))
    args = i == 1 ? (Dict("a" => [1, 2]),) : i == 2 ? ([1.5, -2.0, 0.25],) : (100,)
    local r
    t = @elapsed r = try Base.invokelatest(f, args...); :ok catch e; e end
    println("E12 case $i: $(t)s => ", r isa Symbol ? r : "FALSE POSITIVE? $(typeof(r)): $(sprint(showerror, r))")
end
