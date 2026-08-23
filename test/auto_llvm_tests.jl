@testitem "Auto LLVM IR" tags = [:auto] begin
    using BorrowChecker
    using PerformanceTestTools: @include

    @include("auto_llvm_ir_tests.jl")
    # Important to run the LLVM IR tests in a new julia process with
    # things like --code-coverage disabled.
end
