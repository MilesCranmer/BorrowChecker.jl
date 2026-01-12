using TestItems
using TestItemRunner
using BorrowChecker

include("ownership_tests.jl")
include("reference_tests.jl")
include("feature_tests.jl")
include("integration_tests.jl")
include("complex_macros.jl")
include("mutex_tests.jl")
include("auto_borrow_checker_tests.jl")
include("auto_printing_tests.jl")
include("auto_hygiene_integration_tests.jl")
include("dynamic_expressions_integration_tests.jl")

@static if VERSION < v"1.14.0-"
    @testitem "Aqua" begin
        using Aqua

        Aqua.test_all(BorrowChecker)
    end
end

@testitem "JET tests" begin
    if VERSION >= v"1.10.0" && VERSION < v"1.13.0-DEV.0"
        test_jet_file = joinpath((@__DIR__), "test_jet.jl")
        run(`$(Base.julia_cmd()) --startup-file=no $test_jet_file`)
    end
end

const testitem_name_filter = get(ENV, "BORROWCHECKER_TESTITEM", "")
const only_auto = lowercase(get(ENV, "BORROWCHECKER_ONLY_AUTO", "")) in ("1", "true", "yes")
const auto_supported = VERSION >= v"1.12.0" && isdefined(Base, :code_ircode_by_type)

if only_auto && !auto_supported
    error("BORROWCHECKER_ONLY_AUTO requires Julia >= 1.12 with Base.code_ircode_by_type")
end

filter = if !isempty(testitem_name_filter)
    ti -> ti.name == testitem_name_filter && (auto_supported || !(:auto in ti.tags))
elseif only_auto
    ti -> :auto in ti.tags
elseif !auto_supported
    ti -> !(:auto in ti.tags)
else
    nothing
end

@run_package_tests filter = filter
