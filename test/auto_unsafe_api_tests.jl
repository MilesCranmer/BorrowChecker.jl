@testitem "Auto @safe/@unsafe API" tags = [:auto] begin
    using Test
    using BorrowChecker

    @test Symbol("@safe") in names(BorrowChecker)
    @test Symbol("@unsafe") in names(BorrowChecker)
    @test Symbol("@safe") in names(BorrowChecker.Auto)
    @test Symbol("@unsafe") in names(BorrowChecker.Auto)

    # Regression test: `@unsafe` should be valid at module top-level (no `local` binding).
    @test (@eval BorrowChecker.@unsafe begin
        1 + 2
    end) == 3

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

    # One-line method form should also be accepted by `@safe` (exercises method-definition matcher).
    BorrowChecker.@safe _bc_safe_oneliner(x) = x + 1
    @test _bc_safe_oneliner(1) == 2

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

    BorrowChecker.@unsafe function _bc_unsafe_function_definition()
        x = [1, 2, 3]
        y = x
        push!(x, 1) # would normally be a borrow-check violation
        return y
    end

    BorrowChecker.@safe scope=:all function _bc_call_unsafe_function_scope_all_should_pass()
        return _bc_unsafe_function_definition()
    end

    @test _bc_call_unsafe_function_scope_all_should_pass() == [1, 2, 3, 1]

    BorrowChecker.@unsafe _bc_unsafe_function_definition_short() = _bc_unsafe_function_definition()
    @test _bc_unsafe_function_definition_short() == [1, 2, 3, 1]

    function unwrap_escape(ex)
        return (ex isa Expr && ex.head === :escape) ? ex.args[1] : ex
    end

    let ex = unwrap_escape(macroexpand(@__MODULE__, :(BorrowChecker.@unsafe function _bc_unsafe_def_macroexpand()
            return 1
        end)))
        @test ex isa Expr && ex.head === :function
        body = ex.args[2]
        @test body isa Expr && body.head === :block
        @test body.args[1] == Expr(:meta, :borrow_checker_unsafe)
        @test !any(a -> a isa LineNumberNode, body.args[1:1]) # meta first
        @test any(a -> a isa LineNumberNode, body.args)
    end

    let ex = unwrap_escape(macroexpand(@__MODULE__, :(BorrowChecker.@unsafe _bc_unsafe_def_oneliner_macroexpand() = (1 + 2))))
        @test ex isa Expr && ex.head === :function
        body = ex.args[2]
        @test body isa Expr && body.head === :block
        @test body.args[1] == Expr(:meta, :borrow_checker_unsafe)
        @test any(a -> a isa LineNumberNode, body.args)
    end

    # Exercise the fallback lineinfo insertion in `@unsafe` by passing a programmatically
    # constructed function body that lacks a leading LineNumberNode.
    let fname = gensym(:_bc_unsafe_no_lineinfo)
        sig = Expr(:call, fname)
        raw_body = Expr(
            :block,
            :(x = [1, 2, 3]),
            :(y = x),
            :(push!(x, 1)),
            :(y),
        )
        def = Expr(:function, sig, raw_body)
        @eval BorrowChecker.@unsafe $def

        @eval BorrowChecker.@safe scope=:all function $(Symbol(fname, :_caller))()
            return $fname()
        end

        @test @eval($(Symbol(fname, :_caller))()) == [1, 2, 3, 1]
    end

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
        #! format: off
        @unsafe begin push!(x, 1) end; push!(x, 2) # shares a source line with the unsafe block
        #! format: on
        return y
    end

    @test_throws BorrowChecker.Auto.BorrowCheckError _bc_unsafe_line_mask_demo()
end

@testitem "More complex unsafe branches" tags = [:auto] begin
    using Test
    using BorrowChecker
    using BorrowChecker.Auto: BorrowCheckError

    @safe function add_halves!(a::Vector)
        n = length(a) ÷ 2
        @unsafe begin
            left = @view a[1:n]
            right = @view a[(n + 1):(2n)]
            left .+= right
        end
        return a
    end

    @test add_halves!([1, 2, 3, 4, 5, 6])[1:3] == [5, 7, 9]

    @safe function add_halves_bad!(a::Vector)
        n = length(a) ÷ 2
        begin
            left = @view a[1:n]
            right = @view a[(n + 1):(2n)]
            left .+= right
        end
        return a
    end

    @test_throws BorrowCheckError add_halves_bad!([1, 2, 3, 4, 5, 6])

    @safe function _bc_unsafe_within_tuple()
        x = [1, 2, 3]
        y = x
        ((@unsafe push!(x, 1)), push!(x, 2))
        return y
    end
    @test_throws BorrowCheckError _bc_unsafe_within_tuple()

    @safe function _bc_unsafe_within_tuple_2()
        x = [1, 2, 3]
        y = x
        ((@unsafe push!(x, 1)), (@unsafe push!(x, 2)))
        return y
    end
    @test _bc_unsafe_within_tuple_2() == [1, 2, 3, 1, 2]
end
