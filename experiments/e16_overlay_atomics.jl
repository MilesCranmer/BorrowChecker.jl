# E16: Manual overlay, seq-cst atomics and Lifetime bookkeeping
println("Julia: ", VERSION)
using BorrowChecker, BenchmarkTools
using InteractiveUtils: code_llvm

@own :mut x = Ref(0.0)
function bump!(x)
    for _ in 1:10^5
        x[] = x[] + 1.0
    end
end
print("bump! through OwnedMut: ")
b1 = @benchmark bump!($x)
show(stdout, MIME"text/plain"(), minimum(b1)); println()
y = Ref(0.0)
print("bump! raw Ref:          ")
b2 = @benchmark bump!($y)
show(stdout, MIME"text/plain"(), minimum(b2)); println()
println("ratio (owned/raw, min) = ", minimum(b1).time / minimum(b2).time)

@own :mut v = [1.0]
function refchurn(v)
    @lifetime lt begin
        s = 0.0
        for _ in 1:10^4
            @ref ~lt r = v
            s += sum(r)
        end
        s
    end
end
refchurn(v)
print("@ref churn (10^4 refs): ")
b3 = @benchmark refchurn($v)
show(stdout, MIME"text/plain"(), minimum(b3)); println()
println("ns per @ref+sum(1-elem) = ", minimum(b3).time / 10^4)

# Ordering claim: look for seq_cst (or other orderings) in is_moved
io = IOBuffer()
code_llvm(io, BorrowChecker.TypesModule.is_moved, Tuple{typeof(x)}; debuginfo=:none)
llvm = String(take!(io))
println("is_moved LLVM IR orderings: seq_cst=", count("seq_cst", llvm),
        " acquire=", count(r"\bacquire\b", llvm),
        " monotonic=", count("monotonic", llvm),
        " unordered=", count("unordered", llvm))
println("--- is_moved LLVM ---")
println(llvm)
