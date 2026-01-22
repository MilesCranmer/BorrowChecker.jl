using BorrowChecker
using InteractiveUtils: code_llvm
using Test: @test

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

function llvm_ir_unsafe_idempotent()
    m = Module(gensym(:BCLLVMUnsafe))
    Core.eval(m, :(import BorrowChecker as BC))

    body = quote
        x = Ref(0)
        y = x
        x[] = 1
        y[]
    end

    Core.eval(m, :(f_plain_plain() = $body))
    Core.eval(m, :(BC.@safe f_safe_plain() = $body))
    Core.eval(m, :(BC.@safe f_safe_unsafe() = BC.@unsafe $body))

    plain = Core.eval(m, :f_plain_plain)
    safe_plain = Core.eval(m, :f_safe_plain)
    safe_unsafe = Core.eval(m, :f_safe_unsafe)

    ll_plain = sprint((args...) -> code_llvm(args...; debuginfo=:none), plain, Tuple{})
    ll_safe_plain =
        sprint((args...) -> code_llvm(args...; debuginfo=:none), safe_plain, Tuple{})
    ll_safe_unsafe =
        sprint((args...) -> code_llvm(args...; debuginfo=:none), safe_unsafe, Tuple{})

    function normalize_llvm(ll::AbstractString)
        lines = split(ll, "\n")
        filter!(l -> !isempty(l), lines)
        filter!(l -> !startswith(l, ";"), lines)
        joined = join(lines, "\n")
        return replace(joined, r"^(define\s+.*\s+@)[^\s\(]+"m => s"\1FUNC")
    end

    @test normalize_llvm(ll_plain) == normalize_llvm(ll_safe_unsafe)
    @test !occursin("_generated_assert_safe", ll_plain)
    @test !occursin("_generated_assert_safe", ll_safe_unsafe)
    @test occursin("_generated_assert_safe", ll_safe_plain)

    return nothing
end

llvm_ir_unsafe_idempotent()
