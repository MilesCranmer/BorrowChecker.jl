using BorrowChecker
using InteractiveUtils: code_llvm
using Test: @test, @test_throws

function llvm_ir_minimal()
    m = Module(gensym(:BCLLVM))
    Core.eval(m, :(import BorrowChecker as BC))
    Core.eval(m, :(BC.@safe f(x::Int) = x))

    f = Core.eval(m, :f)

    function normalize_llvm(ll::AbstractString)
        lines = split(ll, "\n")
        filter!(l -> !isempty(l), lines)
        filter!(l -> !startswith(l, ";"), lines)
        return lines
    end

    llvm_ir = sprint((args...) -> code_llvm(args...; debuginfo=:none), f, (Int,))
    lines = normalize_llvm(llvm_ir)
    joined = join(lines, "\n")

    @test !occursin("gc_pool_alloc", llvm_ir)
    @test !occursin("_generated_assert_safe", joined)
    @test !occursin("BorrowChecker", joined)

    # For a trivial function, we expect just:
    #   define ...
    #   top:
    #   ret ...
    #   }
    if length(lines) != 4
        @show lines
    end
    @test length(lines) == 4

    return nothing
end

llvm_ir_minimal()
