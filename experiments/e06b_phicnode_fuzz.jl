# E6b: fuzzer -- random try/catch/finally functions over Vector{Int} locals,
# @safe-wrapped; count AssertionErrors vs BorrowCheckErrors vs clean.
println("Julia: ", VERSION)
import BorrowChecker
import Random
Random.seed!(42)

const STMTS = [
    v -> :(push!($v, 1)),
    v -> :(sort!($v)),
    v -> :($v = copy($v)),
    v -> :(sum($v)),
    v -> :($v = [9]),
]

randstmt(vars) = STMTS[rand(1:end)](vars[rand(1:end)])

function randbody(vars, depth)
    n = rand(1:3)
    stmts = Any[randstmt(vars) for _ in 1:n]
    if depth > 0 && rand() < 0.7
        inner = randtry(vars, depth - 1)
        insert!(stmts, rand(1:(n + 1)), inner)
    end
    return Expr(:block, stmts...)
end

function randtry(vars, depth)
    tryb = randbody(vars, depth)
    catchb = randbody(vars, depth)
    if rand() < 0.4
        finb = randbody(vars, depth)
        return Expr(:try, tryb, :e, catchb, finb)
    elseif rand() < 0.3
        return Expr(:try, tryb, false, false, randbody(vars, depth))  # try/finally
    else
        return Expr(:try, tryb, :e, catchb)
    end
end

asserts = 0; borrows = 0; clean = 0; other = 0
first_assert = nothing
for i in 1:200
    fname = Symbol("fuzz_", i)
    vars = [:a, :b]
    body = quote
        a = [1, 2]
        b = [3]
        $(randtry(vars, 2))
        $(rand() < 0.5 ? :(return a) : :(return (a, b)))
    end
    ex = Expr(:function, Expr(:call, fname), body)
    f = try
        Core.eval(Main, :(BorrowChecker.@safe $ex))
    catch e
        global other += 1
        continue
    end
    r = try
        Base.invokelatest(f)
        global clean += 1
        nothing
    catch e
        if e isa AssertionError
            global asserts += 1
            global first_assert = first_assert === nothing ? (i, e.msg, string(ex)) : first_assert
        elseif occursin("BorrowCheck", string(typeof(e)))
            global borrows += 1
        else
            global other += 1
        end
    end
end
println("E6b fuzz: asserts=$asserts borrowcheck_errors=$borrows clean=$clean other=$other")
if first_assert !== nothing
    println("First assertion at case $(first_assert[1]): $(first_assert[2])")
    println("Function:\n$(first_assert[3])")
end
println(asserts > 0 ? "claim CONFIRMED" : "no assertion reached in 200 cases (claim about *reachability* not demonstrated; logic inversion still present statically)")
