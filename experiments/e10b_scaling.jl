# E10b: first-check wall time vs statement count (no profiling overhead).
println("Julia: ", VERSION)
import BorrowChecker
BorrowChecker.@safe warm() = sum(push!(Int[], 1))
warm()
for n in (250, 500, 1000, 2000)
    fname = Symbol("big_", n)
    body = [:(push!(x, $i)) for i in 1:n]
    Core.eval(Main, quote
        BorrowChecker.@safe function $fname()
            x = Int[]
            $(body...)
            return x
        end
    end)
    t = @elapsed try Base.invokelatest(getfield(Main, fname)) catch end
    println("stmts=$n first-check+run: $(round(t; sigdigits=4))s")
end
