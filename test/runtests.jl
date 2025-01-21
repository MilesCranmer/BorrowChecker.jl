using TestItems
using TestItemRunner
using BorrowChecker

include("ownership_tests.jl")
include("reference_tests.jl")
include("feature_tests.jl")
include("integration_tests.jl")

@testitem "Aqua" begin
    using Aqua

    Aqua.test_all(BorrowChecker)
end

@run_package_tests
