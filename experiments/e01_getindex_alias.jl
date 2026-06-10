# E1: Array element extraction creates no alias
println("Julia: ", VERSION)
import BorrowChecker

# Test: element extraction
BorrowChecker.@safe function f1(outer::Vector{Vector{Int}})
    a = outer[1]
    b = outer[1]
    push!(a, 2)     # write to a while alias b is live
    return b
end
println("E1a: ", try f1([[1]]); "NO ERROR (claim CONFIRMED)" catch e; "threw $(typeof(e)) (claim FALSIFIED): $(sprint(showerror, e))" end)

# Control: same shape through a struct field
mutable struct W1; v::Vector{Int}; end
BorrowChecker.@safe function g1(w::W1)
    a = w.v
    b = w.v
    push!(a, 2)
    return b
end
println("E1b control: ", try g1(W1([1])); "NO ERROR (control failed; aliasing detection broken more generally)" catch e; "threw $(typeof(e)) (control OK): $(first(sprint(showerror, e), 200))" end)
