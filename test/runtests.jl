using TestItems
using TestItemRunner
using BorrowChecker

include("ownership_tests.jl")
include("reference_tests.jl")
include("feature_tests.jl")
include("integration_tests.jl")
include("complex_macros.jl")
include("mutex_tests.jl")
include("experimental_borrow_checker_tests.jl")
include("experimental_printing_tests.jl")
include("experimental_hygiene_integration_tests.jl")
include("dynamic_expressions_integration_tests.jl")

@static if VERSION < v"1.14.0-"
    @testitem "Aqua" begin
        using Aqua

        Aqua.test_all(BorrowChecker)
    end
end

@testitem "JET tests" begin
    if VERSION >= v"1.10.0" && VERSION < v"1.12.0-DEV.0"
        test_jet_file = joinpath((@__DIR__), "test_jet.jl")
        run(`$(Base.julia_cmd()) --startup-file=no $test_jet_file`)
    end
end

testitem_name_filter = get(ENV, "BORROWCHECKER_TESTITEM", "")
include_unstable =
    lowercase(get(ENV, "BORROWCHECKER_INCLUDE_UNSTABLE", "")) in ("1", "true", "yes")

filter = if !isempty(testitem_name_filter)
    ti -> ti.name == testitem_name_filter
elseif !include_unstable
    ti -> !(:unstable in ti.tags)
else
    nothing
end

@run_package_tests filter = filter
