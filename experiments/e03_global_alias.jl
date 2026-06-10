# E3: Globals loaded twice never alias
println("Julia: ", VERSION)
import BorrowChecker
const G3 = [1, 2, 3]
BorrowChecker.@safe function f3()
    a = G3
    b = G3
    push!(a, 4)
    return b
end
println("E3: ", try f3(); "NO ERROR (claim CONFIRMED)" catch e; "threw (claim FALSIFIED): $(sprint(showerror, e))" end)
