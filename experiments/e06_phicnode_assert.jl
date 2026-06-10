# E6: PhiCNode assertion can fire on legal IR
println("Julia: ", VERSION)
import BorrowChecker

BorrowChecker.@safe function t1()
    x = [1]
    y = try
        push!(x, 2); x
    catch
        x
    end
    return y
end

BorrowChecker.@safe function t2(v::Vector{Int})
    local y
    try
        y = copy(v)
    catch e
        y = v
    end
    return y
end

BorrowChecker.@safe function t3()
    x = [1]
    try
        try
            push!(x, 2)
        catch
            push!(x, 3)
        end
    catch
        x = [9]
    end
    return x
end

function classify(thunk)
    try
        thunk()
        "ok"
    catch e
        if e isa AssertionError
            "ASSERTION ERROR (claim CONFIRMED): $(e.msg)"
        else
            "$(typeof(e)): $(first(sprint(showerror, e), 200))"
        end
    end
end

println("simple  => ", classify(() -> t1()))
println("rethrow => ", classify(() -> t2([1, 2])))
println("nested  => ", classify(() -> t3()))
