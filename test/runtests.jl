using TestItems
using TestItemRunner
using BorrowChecker

include("auto_borrow_checker_tests.jl")
include("auto_llvm_tests.jl")
include("auto_printing_tests.jl")
include("auto_hygiene_integration_tests.jl")
include("dynamic_expressions_integration_tests.jl")
include("auto_unsafe_api_tests.jl")

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

@testitem "Unsupported Julia stubs" begin
    if VERSION >= v"1.14.0-"
        using Test

        m = Module(gensym(:BCUnsupported))
        Core.eval(m, :(import BorrowChecker))
        @test_logs (:warn, r"not supported") Core.eval(
            m, :(BorrowChecker.@safe stub_safe(x) = x + 1)
        )
        @test Core.eval(m, :(stub_safe(1))) == 2
        @test Core.eval(m, :(BorrowChecker.@unsafe (1 + 1))) == 2
    end
end

const testitem_name_filter = get(ENV, "BORROWCHECKER_TESTITEM", "")
const checker_supported =
    v"1.12.0-" <= VERSION < v"1.14.0-" && isdefined(Base, :code_ircode_by_type)

filter = if !isempty(testitem_name_filter)
    ti -> ti.name == testitem_name_filter && (checker_supported || !(:auto in ti.tags))
elseif !checker_supported
    ti -> !(:auto in ti.tags)
else
    nothing
end

@run_package_tests filter = filter
