@testitem "Auto @auto" tags = [:auto] begin
    using TestItems
    using BorrowChecker

    using BorrowChecker.Auto: BorrowCheckError, @auto

    Base.@noinline fakewrite(x) = Base.inferencebarrier(x)

    mutable struct Box
        x::Int
    end

    mutable struct A
        x::Int
    end

    struct B
        a::A
    end

    mutable struct C
        v
    end

    struct Wrap
        x::Vector{Int}
    end

    BorrowChecker.Auto.@auto function _bc_bad_alias()
        x = [1, 2, 3]
        y = x
        x[1] = 0
        return y
    end

    BorrowChecker.Auto.@auto function _bc_ok_copy()
        x = [1, 2, 3]
        y = copy(x)
        x[1] = 0
        return y
    end

    BorrowChecker.Auto.@auto function _bc_bad_unknown_call(vf)
        x = [1, 2, 3]
        f = only(vf)
        f(x)
        x[1] = 0
        return x
    end

    BorrowChecker.Auto.@auto function _bc_bad_alias_mutable_struct()
        x = Box(1)
        y = x
        x.x = 0
        return y
    end

    BorrowChecker.Auto.@auto function _bc_ok_copy_mutable_struct()
        x = Box(1)
        y = Box(x.x)
        x.x = 0
        return y
    end

    BorrowChecker.Auto.@auto function _bc_bad_struct_of_struct()
        a = A(1)
        b = B(a)
        c = b
        b.a.x = 0
        return c
    end

    BorrowChecker.Auto.@auto function _bc_ok_struct_of_struct()
        a = A(1)
        b = B(a)
        c = B(A(b.a.x))
        b.a.x = 0
        return c
    end

    g!(x) = (push!(x, 1); nothing)

    const _BC_ESCAPE_CACHE = Any[]
    _bc_consumes(x) = (push!(_BC_ESCAPE_CACHE, x); nothing)
    const D = Dict{Any,Any}()

    @testset "g!(y) should not require deleting x" begin
        BorrowChecker.Auto.@auto function _bc_g_alias_ok()
            x = [1, 2, 3]
            y = x
            g!(y)
            return y
        end

        @test _bc_g_alias_ok() == [1, 2, 3, 1]
    end

    @testset "effects inferred from IR (no naming heuristics)" begin
        h(x) = (push!(x, 1); nothing)

        BorrowChecker.Auto.@auto function _bc_nonbang_mutator_bad()
            x = [1, 2, 3]
            y = x
            h(x)
            return y
        end

        mut_second!(a, b) = (push!(b, 1); nothing)

        BorrowChecker.Auto.@auto function _bc_bang_mutates_second_bad()
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

    BorrowChecker.Auto.@auto function _bc_bad_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Auto.@auto function _bc_bad_closure_body_with_arg(z)
        f = () -> begin
            x = z
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Auto.@auto function _bc_ok_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = copy(x)
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Auto.@auto function _bc_ok_closure_body_with_arg(z)
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

    BorrowChecker.Auto.@auto function _bc_ok_phi_ternary(cond::Bool)
        x = [1, 2, 3]
        y = cond ? x : x
        push!(y, 1)
        return y
    end

    @noinline _ret1(x) = x

    BorrowChecker.Auto.@auto function _bc_ok_identity_call()
        x = [1, 2, 3]
        y = _ret1(x)
        push!(y, 1)
        return y
    end

    BorrowChecker.Auto.@auto function _bc_bad_view_alias()
        x = [1, 2, 3, 4]
        y = view(x, 1:2)
        push!(x, 9)
        return collect(y)
    end

    BorrowChecker.Auto.@auto function _bc_bad_closure_capture()
        x = [1, 2, 3]
        y = x
        f = () -> (push!(x, 9); nothing)
        f()
        return y
    end

    BorrowChecker.Auto.@auto function _bc_bad_closure_capture_nested()
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

    BorrowChecker.Auto.@auto function _bc_ok_closure_capture_readonly()
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

    @auto function _bc_ok_kwcall()
        x = [1, 2, 3]
        y = copy(x)
        return sum(f_kwcall_ok(; x=x, y=y))
    end

    @auto function _bc_ok_kwcall_mut()
        x = [1, 2, 3]
        y = copy(x)
        return sum(f_kwcall_ok_mut(; x=x, y=y))
    end

    @auto function _bc_bad_kwcall_alias_should_error()
        x = [1, 2, 3]
        y = x
        return sum(f_kwcall_alias_bad(; x=x, y=y))
    end

    @test _bc_ok_kwcall() == 12
    @test _bc_ok_kwcall_mut() == 14
    @test_throws BorrowCheckError _bc_bad_kwcall_alias_should_error()

    @testset "escape/store is treated as consume (move)" begin
        empty!(_BC_ESCAPE_CACHE)

        @auto function _bc_escape_after_store_should_error()
            x = [1, 2, 3]
            _bc_consumes(x)
            return x
        end

        @test_throws BorrowCheckError _bc_escape_after_store_should_error()
    end

    @testset "escape/store does not move non-owned values" begin
        empty!(_BC_ESCAPE_CACHE)

        @auto function _bc_escape_bits_ok()
            x = (1, 2, 3)
            _bc_consumes(x)
            return x
        end

        @test _bc_escape_bits_ok() == (1, 2, 3)
    end

    @testset "setfield!/Ref store moves owned values" begin
        @auto function _bc_ref_store_moves_owned()
            r = Ref{Any}()
            x = [1, 2, 3]
            r[] = x
            return x
        end

        @test_throws BorrowCheckError _bc_ref_store_moves_owned()
    end

    @testset "setfield!/Ref store does not move isbits" begin
        @auto function _bc_ref_store_bits_ok()
            r = Ref{Any}()
            x = (1, 2, 3)
            r[] = x
            return x
        end

        @test _bc_ref_store_bits_ok() == (1, 2, 3)
    end

    @testset "mutable field store moves owned values" begin
        @auto function _bc_mutable_field_store_moves_owned()
            c = C(nothing)
            x = [1, 2, 3]
            c.v = x
            return x
        end

        @test_throws BorrowCheckError _bc_mutable_field_store_moves_owned()
    end

    @testset "unknown call does not consume non-owned values" begin
        @auto function _bc_unknown_call_bits_ok(vf)
            x = (1, 2, 3)
            f = only(vf)
            f(x)
            return x
        end

        @test _bc_unknown_call_bits_ok(Any[identity]) == (1, 2, 3)
    end

    @testset "immutable wrapper containing owned field is owned" begin
        empty!(_BC_ESCAPE_CACHE)

        @auto function _bc_escape_wrap_should_error()
            w = Wrap([1, 2, 3])
            _bc_consumes(w)
            return w
        end

        @test_throws BorrowCheckError _bc_escape_wrap_should_error()
    end

    @testset "symbols are not moved" begin
        empty!(_BC_ESCAPE_CACHE)

        @auto function _bc_escape_symbol_ok()
            x = :a
            _bc_consumes(x)
            return x
        end

        @test _bc_escape_symbol_ok() == :a
    end

    @testset "Dict setindex! key escapes" begin
        empty!(D)

        @auto function _bc_dict_key_escape_should_error()
            x = [1, 2, 3]
            D[x] = 4
            return x
        end

        @test_throws BorrowCheckError _bc_dict_key_escape_should_error()

        empty!(D)

        @auto function _bc_dict_key_copy_ok()
            x = [1, 2, 3]
            D[copy(x)] = 4
            return x
        end

        @test _bc_dict_key_copy_ok() == [1, 2, 3]
    end

    @testset "__bc_assert_safe__ short-circuits on cache hit" begin
        local_f(x) = x
        tt = Tuple{typeof(local_f),Int}

        BorrowChecker.Auto.__bc_assert_safe__(tt)
        GC.gc()

        alloc = @allocated BorrowChecker.Auto.__bc_assert_safe__(tt)
        @test alloc < 200_000
    end

    @testset "summary cache determinism" begin
        Base.@lock BorrowChecker.Auto._summary_state begin
            empty!(BorrowChecker.Auto._summary_state[].summary_cache)
            empty!(BorrowChecker.Auto._summary_state[].tt_summary_cache)
            empty!(BorrowChecker.Auto._summary_state[].summary_inprogress)
            empty!(BorrowChecker.Auto._summary_state[].tt_summary_inprogress)
        end

        deep1(x) = x
        deep2(x) = deep1(x)
        deep3(x) = deep2(x)

        cfg = BorrowChecker.Auto.Config(; max_summary_depth=2)
        tt = Tuple{typeof(deep3),Vector{Int}}

        BorrowChecker.Auto._summary_for_tt(tt, cfg; depth=cfg.max_summary_depth)

        function latest_entry()
            Base.@lock BorrowChecker.Auto._summary_state begin
                best_key = nothing
                for k in keys(BorrowChecker.Auto._summary_state[].tt_summary_cache)
                    (k[1] === tt && k[3] == cfg) || continue
                    (best_key === nothing || k[2] > best_key[2]) && (best_key = k)
                end
                best_key === nothing && error("missing cache entry")
                return BorrowChecker.Auto._summary_state[].tt_summary_cache[best_key]
            end
        end

        entry1 = latest_entry()
        @test entry1.over_budget == true

        BorrowChecker.Auto._summary_for_tt(tt, cfg; depth=0)
        entry2 = latest_entry()
        @test entry2.over_budget == false
    end

    @testset "summary cache respects Config" begin
        Base.@lock BorrowChecker.Auto._summary_state begin
            empty!(BorrowChecker.Auto._summary_state[].summary_cache)
            empty!(BorrowChecker.Auto._summary_state[].tt_summary_cache)
            empty!(BorrowChecker.Auto._summary_state[].summary_inprogress)
            empty!(BorrowChecker.Auto._summary_state[].tt_summary_inprogress)
        end

        # This callee has an *unknown* dynamic call in its body. Under
        # `unknown_call_policy=:consume` it should be summarized as consuming `x`,
        # while under `:ignore` it should not.
        function _cfg_sensitive_callee(x, vf)
            f = only(vf)
            f(x)
            return x
        end

        cfg_ignore = BorrowChecker.Auto.Config(; unknown_call_policy=:ignore)
        cfg_consume = BorrowChecker.Auto.Config(; unknown_call_policy=:consume)
        tt = Tuple{typeof(_cfg_sensitive_callee),Vector{Int},Vector{Any}}

        world = Base.get_world_counter()
        BorrowChecker.Auto._with_reflection_ctx(
            () -> begin
                s1 = BorrowChecker.Auto._summary_for_tt(tt, cfg_ignore; depth=0)
                s2 = BorrowChecker.Auto._summary_for_tt(tt, cfg_consume; depth=0)
                @test s1 !== nothing
                @test s2 !== nothing
                @test isempty(s1.consumes)
                @test !isempty(s2.consumes)
            end,
            world,
        )
    end

    @testset "Registry override API" begin
        BorrowChecker.Auto.register_effects!(fakewrite; writes=(2,))

        @auto function bc_registry_override()
            x = [1, 2, 3]
            y = x
            z = fakewrite(x)
            z === y || error("unexpected")
            return y
        end

        @test_throws BorrowCheckError bc_registry_override()
    end

    @testset "@auto one-line method form" begin
        # Hits the `ex.head === :(=)` + `_is_method_definition_lhs` branch in the macro.
        BorrowChecker.Auto.@auto _bc_oneliner_bad() = begin
            x = [1, 2, 3]
            y = x
            x[1] = 0
            y
        end

        @test_throws BorrowCheckError _bc_oneliner_bad()
    end
end
