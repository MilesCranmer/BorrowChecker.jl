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

@testitem "JET" begin
    if !(VERSION >= v"1.10.0" && VERSION < v"1.12.0-DEV.0")
        # TODO: Turn on when JET is ready
        exit(0)
    end

    using BorrowChecker
    using JET

    JET.test_package(BorrowChecker; target_defined_modules=true)
end

@run_package_tests
