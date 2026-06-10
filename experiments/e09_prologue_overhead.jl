# E9: Per-call prologue overhead (runtime tt construction)
println("Julia: ", VERSION)
import BorrowChecker, BenchmarkTools
using BenchmarkTools
BorrowChecker.@safe fsafe9(x::Int) = x + 1
fraw9(x::Int) = x + 1
fsafe9(1); fraw9(1)  # warm
b1 = @benchmark fsafe9(i) setup = (i = rand(1:10))
b2 = @benchmark fraw9(i) setup = (i = rand(1:10))
println("E9: safe min=", minimum(b1).time, "ns median=", BenchmarkTools.median(b1).time,
        "ns | raw min=", minimum(b2).time, "ns median=", BenchmarkTools.median(b2).time,
        "ns | ratio(min)=", minimum(b1).time / minimum(b2).time,
        " overhead(min)=", minimum(b1).time - minimum(b2).time, "ns")

using Profile
@profile (for i in 1:10^6; fsafe9(i); end)
println("--- profile (flat, mincount=100) ---")
Profile.print(; mincount=100, format=:flat)
