# E6c: minimal reproducer for the PhiCNode assertion (checker.jl:47).
# Ordinary try/catch/finally with a rebinding in the catch block.
println("Julia: ", VERSION)
import BorrowChecker

BorrowChecker.@safe function n2()
    a = [1, 2]
    try
        push!(a, 1)
    catch e
        a = copy(a)
    finally
        sum(a)
    end
    return a
end
try
    n2()
    println("no error (FALSIFIED on this build)")
catch e
    println(typeof(e), ": ", sprint(showerror, e))
    println(e isa AssertionError ? "AssertionError => claim CONFIRMED" : "not an AssertionError")
end

# Side finding: try/finally WITHOUT rebinding is a false-positive BorrowCheckError
BorrowChecker.@safe function m1()
    a = [1, 2]
    try
        push!(a, 1)
    finally
        sum(a)
    end
    return a
end
println("try/finally no-rebind (semantically fine): ",
        try m1(); "ok" catch e; "$(typeof(e)) (false positive)" end)
