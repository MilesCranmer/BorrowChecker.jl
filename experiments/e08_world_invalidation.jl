# E8: World-exact caching means any new method invalidates everything
println("Julia: ", VERSION)
import BorrowChecker

for rep in 1:5
    fsym = Symbol("f8_", rep)
    isym = Symbol("inner8_", rep)
    usym = Symbol("unrelated8_", rep)
    Core.eval(Main, quote
        $isym(x) = (push!(x, 1); sum(x))
        BorrowChecker.@safe function $fsym()
            x = collect(1:50)
            $isym(x)
        end
    end)
    f = getfield(Main, fsym)
    t_cold = @elapsed Base.invokelatest(f)
    t_warm = @elapsed Base.invokelatest(f)
    t_warm2 = @elapsed Base.invokelatest(f)
    Core.eval(Main, :($usym() = 1))   # bumps world counter, touches nothing f8 uses
    t_after_bump = @elapsed Base.invokelatest(f)
    t_after_warm = @elapsed Base.invokelatest(f)
    println("E8 rep$rep: cold=$(round(t_cold; sigdigits=4))s warm=$(round(t_warm; sigdigits=6))s warm2=$(round(t_warm2; sigdigits=6))s after_unrelated_def=$(round(t_after_bump; sigdigits=4))s after_warm=$(round(t_after_warm; sigdigits=6))s ratio_bump/warm=$(round(t_after_bump / t_warm2; sigdigits=4)) ratio_bump/cold=$(round(t_after_bump / t_cold; sigdigits=4))")
end
println("CONFIRMED if t_after_bump >> t_warm (within ~2x of t_cold). FALSIFIED if ~= t_warm.")
