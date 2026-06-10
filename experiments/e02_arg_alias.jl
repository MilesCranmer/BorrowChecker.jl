# E2: Argument aliasing f(v, v) is invisible
println("Julia: ", VERSION)
import BorrowChecker
BorrowChecker.@safe function h2(x::Vector{Int}, y::Vector{Int})
    push!(x, 1)
    return sum(y)
end
v = [1, 2]
println("E2: ", try h2(v, v); "NO ERROR (claim CONFIRMED)" catch e; "threw (claim FALSIFIED): $(sprint(showerror, e))" end)
