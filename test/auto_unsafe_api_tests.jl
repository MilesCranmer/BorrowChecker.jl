@testitem "Auto @safe/@unsafe API" tags = [:auto] begin
    using Test
    using BorrowChecker

    @test Symbol("@safe") in names(BorrowChecker)
    @test Symbol("@unsafe") in names(BorrowChecker)
    @test Symbol("@safe") in names(BorrowChecker.Auto)
    @test Symbol("@unsafe") in names(BorrowChecker.Auto)

    @test_deprecated macroexpand(
        @__MODULE__, :(BorrowChecker.@auto function _bc_depwarn_auto()
            return 1
        end)
    )

    BorrowChecker.@safe function _bc_safe_violation_should_error()
        x = [1, 2, 3]
        y = x
        push!(x, 1)
        return y
    end

    @test_throws BorrowChecker.Auto.BorrowCheckError _bc_safe_violation_should_error()

    BorrowChecker.@safe function _bc_safe_with_unsafe_should_pass()
        x = [1, 2, 3]
        y = x
        @unsafe begin
            push!(x, 1)
        end
        return y
    end

    @test _bc_safe_with_unsafe_should_pass() == [1, 2, 3, 1]

    BorrowChecker.@safe function _bc_safe_with_unsafe_inner_should_pass()
        x = [1, 2, 3]
        y = x
        @unsafe begin
            inner() = (push!(x, 1); y)
            inner()
        end
    end

    @test _bc_safe_with_unsafe_inner_should_pass() == [1, 2, 3, 1]

    let unsafe_call = macroexpand(@__MODULE__, :(BorrowChecker.@unsafe begin
            push!(x, 1)
        end))
        @test occursin("borrow_checker_unsafe", sprint(show, unsafe_call))
        @eval BorrowChecker.@safe function _bc_safe_with_preexpanded_unsafe_should_pass()
            x = [1, 2, 3]
            y = x
            $unsafe_call
            return y
        end
    end

    @test _bc_safe_with_preexpanded_unsafe_should_pass() == [1, 2, 3, 1]

    @eval BorrowChecker.@safe function _bc_bare_meta_unsafe_whole_method_should_pass()
        $(Expr(:meta, :borrow_checker_unsafe))
        x = [1, 2, 3]
        y = x
        push!(x, 1) # would normally be a borrow-check violation
        return y
    end

    @test _bc_bare_meta_unsafe_whole_method_should_pass() == [1, 2, 3, 1]

    module _BCUnsafeDisabled
    using BorrowChecker

    BorrowChecker.disable_by_default!(@__MODULE__)

    const expanded = macroexpand(@__MODULE__, :(BorrowChecker.@unsafe begin
        1
    end))

    BorrowChecker.@safe function f()
        x = [1, 2, 3]
        y = x
        @unsafe begin
            push!(x, 1)
        end
        return y
    end
    end

    @test !occursin("borrow_checker_unsafe", sprint(show, _BCUnsafeDisabled.expanded))
    @test _BCUnsafeDisabled.f() == [1, 2, 3, 1]

    BorrowChecker.@safe function _bc_unsafe_line_mask_demo()
        x = [1, 2, 3]
        y = x
        @unsafe begin push!(x, 1) end; push!(x, 2) # shares a source line with the unsafe block
        return y
    end

    @test_throws BorrowChecker.Auto.BorrowCheckError _bc_unsafe_line_mask_demo()
end
