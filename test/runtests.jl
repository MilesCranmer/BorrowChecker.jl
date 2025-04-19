using TestItems
using TestItemRunner
using BorrowChecker

include("ownership_tests.jl")
include("reference_tests.jl")
include("feature_tests.jl")
include("integration_tests.jl")
include("complex_macros.jl")
include("mutex_tests.jl")

@testitem "Aqua" begin
    using Aqua

    Aqua.test_all(BorrowChecker)
end

@testitem "JET tests" begin
    if VERSION >= v"1.10.0" && VERSION < v"1.12.0-DEV.0"
        test_jet_file = joinpath((@__DIR__), "test_jet.jl")
        run(`$(Base.julia_cmd()) --startup-file=no $test_jet_file`)
    end
end

@run_package_tests
