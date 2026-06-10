# E12b: same cases with debug=true; count budget-hit events in the JSONL.
println("Julia: ", VERSION)
ENV["BORROWCHECKER_AUTO_DEBUG_PATH"] = "/tmp/bc_debug.jsonl"
rm("/tmp/bc_debug.jsonl"; force=true)
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
    f = Core.eval(Main, :(BorrowChecker.@safe debug = true $ex))
    args = i == 1 ? (Dict("a" => [1, 2]),) : i == 2 ? ([1.5, -2.0, 0.25],) : (100,)
    local r
    t = @elapsed r = try Base.invokelatest(f, args...); :ok catch e; e end
    println("E12b case $i: $(t)s => ", r isa Symbol ? r : "$(typeof(r))")
end
if isfile("/tmp/bc_debug.jsonl")
    lines = readlines("/tmp/bc_debug.jsonl")
    println("debug JSONL lines: ", length(lines))
    kinds = Dict{String,Int}()
    for l in lines
        m = match(r"\"(?:event|kind|type)\"\s*:\s*\"([^\"]+)\"", l)
        k = m === nothing ? "?" : m.captures[1]
        kinds[k] = get(kinds, k, 0) + 1
    end
    println("event kinds: ", sort(collect(kinds); by=last, rev=true))
    budget = filter(l -> occursin(r"budget|depth|limit"i, l), lines)
    println("budget/depth/limit-mentioning events: ", length(budget))
    for l in budget[1:min(end, 5)]
        println("  ", first(l, 300))
    end
else
    println("no debug file written")
end
