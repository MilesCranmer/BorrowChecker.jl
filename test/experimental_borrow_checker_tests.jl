@testitem "Experimental @borrow_checker" tags = [:unstable] begin
    using TestItems
    using BorrowChecker

    using BorrowChecker.Experimental: BorrowCheckError, @borrow_checker

    mutable struct Box
        x::Int
    end

    mutable struct A
        x::Int
    end

    struct B
        a::A
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_alias()
        x = [1, 2, 3]
        y = x
        x[1] = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_copy()
        x = [1, 2, 3]
        y = copy(x)
        x[1] = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_unknown_call(vf)
        x = [1, 2, 3]
        f = only(vf)
        f(x)
        x[1] = 0
        return x
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_alias_mutable_struct()
        x = Box(1)
        y = x
        x.x = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_copy_mutable_struct()
        x = Box(1)
        y = Box(x.x)
        x.x = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_struct_of_struct()
        a = A(1)
        b = B(a)
        c = b
        b.a.x = 0
        return c
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_struct_of_struct()
        a = A(1)
        b = B(a)
        c = B(A(b.a.x))
        b.a.x = 0
        return c
    end

    g!(x) = (push!(x, 1); nothing)

    @testset "g!(y) should not require deleting x" begin
        BorrowChecker.Experimental.@borrow_checker function _bc_g_alias_ok()
            x = [1, 2, 3]
            y = x
            g!(y)
            return y
        end

        @test _bc_g_alias_ok() == [1, 2, 3, 1]
    end

    @testset "effects inferred from IR (no naming heuristics)" begin
        h(x) = (push!(x, 1); nothing)

        BorrowChecker.Experimental.@borrow_checker function _bc_nonbang_mutator_bad()
            x = [1, 2, 3]
            y = x
            h(x)
            return y
        end

        mut_second!(a, b) = (push!(b, 1); nothing)

        BorrowChecker.Experimental.@borrow_checker function _bc_bang_mutates_second_bad()
            x = [1, 2, 3]
            y = [4]
            z = y
            mut_second!(x, y)
            return z
        end

        @test_throws BorrowCheckError _bc_nonbang_mutator_bad()
        @test_throws BorrowCheckError _bc_bang_mutates_second_bad()
    end

    @test_throws BorrowCheckError _bc_bad_alias()
    @test _bc_ok_copy() == [1, 2, 3]
    @test_throws BorrowCheckError _bc_bad_unknown_call(Any[identity])

    @test_throws BorrowCheckError _bc_bad_alias_mutable_struct()
    @test _bc_ok_copy_mutable_struct().x == 1

    @test_throws BorrowCheckError _bc_bad_struct_of_struct()
    @test _bc_ok_struct_of_struct().a.x == 1

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_body_with_arg(z)
        f = () -> begin
            x = z
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = copy(x)
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_body_with_arg(z)
        f = () -> begin
            x = copy(z)
            y = copy(x)
            push!(x, 9)
            return y
        end
        return f()
    end

    @test_throws BorrowCheckError _bc_bad_closure_body_0arg()
    @test_throws BorrowCheckError _bc_bad_closure_body_with_arg([1, 2, 3])
    @test _bc_ok_closure_body_0arg() == [1, 2, 3]
    @test _bc_ok_closure_body_with_arg([1, 2, 3]) == [1, 2, 3]

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_phi_ternary(cond::Bool)
        x = [1, 2, 3]
        y = cond ? x : x
        push!(y, 1)
        return y
    end

    @noinline _ret1(x) = x

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_identity_call()
        x = [1, 2, 3]
        y = _ret1(x)
        push!(y, 1)
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_view_alias()
        x = [1, 2, 3, 4]
        y = view(x, 1:2)
        push!(x, 9)
        return collect(y)
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_capture()
        x = [1, 2, 3]
        y = x
        f = () -> (push!(x, 9); nothing)
        f()
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_capture_nested()
        x = [1, 2, 3]
        y = x
        f = () -> begin
            g = () -> (push!(x, 9); nothing)
            g()
            return nothing
        end
        f()
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_capture_readonly()
        x = [1, 2, 3]
        y = x
        f = () -> begin
            s = 0
            for i in 1:length(y)
                s += y[i]
            end
            return s
        end
        f()
        return x
    end

    @test _bc_ok_phi_ternary(true) == [1, 2, 3, 1]
    @test _bc_ok_phi_ternary(false) == [1, 2, 3, 1]
    @test _bc_ok_identity_call() == [1, 2, 3, 1]
    @test_throws BorrowCheckError _bc_bad_view_alias()
    @test_throws BorrowCheckError _bc_bad_closure_capture()
    @test_throws BorrowCheckError _bc_bad_closure_capture_nested()
    @test _bc_ok_closure_capture_readonly() == [1, 2, 3]

    f_kwcall_ok(; x, y) = x .+ y
    f_kwcall_ok_mut(; x, y) = (push!(x, 1); push!(y, 1); x .+ y)
    f_kwcall_alias_bad(; x, y) = (push!(x, 1); push!(y, 1); x .+ y)

    @borrow_checker function _bc_ok_kwcall()
        x = [1, 2, 3]
        y = copy(x)
        return sum(f_kwcall_ok(; x=x, y=y))
    end

    @borrow_checker function _bc_ok_kwcall_mut()
        x = [1, 2, 3]
        y = copy(x)
        return sum(f_kwcall_ok_mut(; x=x, y=y))
    end

    @borrow_checker function _bc_bad_kwcall_alias_should_error()
        x = [1, 2, 3]
        y = x
        return sum(f_kwcall_alias_bad(; x=x, y=y))
    end

    @test _bc_ok_kwcall() == 12
    @test _bc_ok_kwcall_mut() == 14
    @test_throws BorrowCheckError _bc_bad_kwcall_alias_should_error()

    @testset "__bc_assert_safe__ short-circuits on cache hit" begin
        local_f(x) = x
        tt = Tuple{typeof(local_f),Int}

        BorrowChecker.Experimental.__bc_assert_safe__(tt)
        GC.gc()

        alloc = @allocated BorrowChecker.Experimental.__bc_assert_safe__(tt)
        @test alloc < 200_000
    end

    @testset "summary cache determinism" begin
        Base.@lock BorrowChecker.Experimental._summary_state begin
            empty!(BorrowChecker.Experimental._summary_state[].summary_cache)
            empty!(BorrowChecker.Experimental._summary_state[].tt_summary_cache)
        end

        deep1(x) = x
        deep2(x) = deep1(x)
        deep3(x) = deep2(x)

        cfg = BorrowChecker.Experimental.Config(; max_summary_depth=2)
        tt = Tuple{typeof(deep3),Vector{Int}}

        BorrowChecker.Experimental._summary_for_tt(tt, cfg; depth=cfg.max_summary_depth)

        function latest_entry()
            Base.@lock BorrowChecker.Experimental._summary_state begin
                best_key = nothing
                for k in keys(BorrowChecker.Experimental._summary_state[].tt_summary_cache)
                    k[1] === tt || continue
                    (best_key === nothing || k[2] > best_key[2]) && (best_key = k)
                end
                best_key === nothing && error("missing cache entry")
                return BorrowChecker.Experimental._summary_state[].tt_summary_cache[best_key]
            end
        end

        entry1 = latest_entry()
        @test entry1.over_budget == true

        BorrowChecker.Experimental._summary_for_tt(tt, cfg; depth=0)
        entry2 = latest_entry()
        @test entry2.over_budget == false
    end
end
