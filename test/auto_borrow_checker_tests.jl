@testitem "Auto @auto" tags = [:auto] begin
    using TestItems
    using BorrowChecker
    using LinearAlgebra

    using BorrowChecker.Auto: BorrowCheckError, @auto

    const BC_TEST_TIMINGS =
        lowercase(get(ENV, "BORROWCHECKER_TEST_TIMINGS", "")) in ("1", "true", "yes")
    const BC_TEST_TIMING_BASE_DEPTH = Ref{Int}(-1)

    if BC_TEST_TIMINGS
        using Test

        mutable struct BCTimedTestSet <: Test.AbstractTestSet
            inner::Test.DefaultTestSet
            start_ns::UInt64
        end

        function BCTimedTestSet(
            desc::AbstractString;
            verbose::Bool=false,
            showtiming::Bool=true,
            failfast::Union{Nothing,Bool}=nothing,
            source=nothing,
            rng=nothing,
        )
            # Only print timings for the direct children of the timing wrapper (top-level
            # `@testset` blocks in this file).
            depth = Test.get_testset_depth()
            if depth == BC_TEST_TIMING_BASE_DEPTH[] + 1
                println("[BC_TEST_BEGIN] ", desc)
            end
            inner = Test.DefaultTestSet(
                desc;
                verbose=verbose,
                showtiming=showtiming,
                failfast=failfast,
                source=source,
                rng=rng,
            )
            return BCTimedTestSet(inner, time_ns())
        end

        Test.record(ts::BCTimedTestSet, t) = Test.record(ts.inner, t)
        Test.print_verbose(ts::BCTimedTestSet) = Test.print_verbose(ts.inner)
        Test.results(ts::BCTimedTestSet) = Test.results(ts.inner)

        function Test.finish(
            ts::BCTimedTestSet; print_results::Bool=Test.TESTSET_PRINT_ENABLE[]
        )
            elapsed_s = (time_ns() - ts.start_ns) / 1e9
            depth = Test.get_testset_depth()
            if depth == BC_TEST_TIMING_BASE_DEPTH[] + 1
                println(
                    "[BC_TEST_END] ",
                    ts.inner.description,
                    "  ",
                    round(elapsed_s; digits=3),
                    "s",
                )
            end
            return Test.finish(ts.inner; print_results=print_results)
        end
    end

    local _bc_timing_ts = nothing
    if BC_TEST_TIMINGS
        using Test
        BC_TEST_TIMING_BASE_DEPTH[] = Test.get_testset_depth()
        _bc_timing_ts = BCTimedTestSet(
            "BorrowChecker.Auto @auto (timings)"; showtiming=false
        )
        Test.push_testset(_bc_timing_ts)
    end

    Base.@noinline fakewrite(x) = Base.inferencebarrier(x)

    BorrowChecker.Auto._ensure_registry_initialized()
    const BC_BUILTIN_EFFECT_KEYS = Base.@lock BorrowChecker.Auto.KNOWN_EFFECTS begin
        collect(keys(BorrowChecker.Auto.KNOWN_EFFECTS[]))
    end

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

    @testset "adversarial overloads (no special-casing overloadables)" begin
        mutable struct _BCGetPropMutates
            x::Vector{Int}
        end

        function Base.getproperty(g::_BCGetPropMutates, s::Symbol)
            if s === :x
                v = getfield(g, :x)
                push!(v, 999)
                return v
            end
            return getfield(g, s)
        end

        BorrowChecker.Auto.@auto function _bc_getproperty_mutates_bad()
            g = _BCGetPropMutates([1, 2, 3])
            y = getfield(g, :x)
            g.x  # calls overloaded getproperty (mutates)
            return y
        end

        @test_throws BorrowCheckError _bc_getproperty_mutates_bad()

        mutable struct _BCSetPropDoesNotMutate
            x::Vector{Int}
        end

        Base.setproperty!(::_BCSetPropDoesNotMutate, ::Symbol, v) = v

        BorrowChecker.Auto.@auto function _bc_setproperty_no_mut_ok()
            g = _BCSetPropDoesNotMutate([1, 2, 3])
            y = g
            g.x = [4, 5, 6]  # calls overloaded setproperty! (does not mutate)
            return y
        end

        @test _bc_setproperty_no_mut_ok().x == [1, 2, 3]

        mutable struct _BCCopyAliases
            x::Vector{Int}
        end

        Base.copy(x::_BCCopyAliases) = x

        BorrowChecker.Auto.@auto function _bc_copy_aliases_bad()
            x = _BCCopyAliases([1, 2, 3])
            y = copy(x)  # aliases by definition
            x.x[1] = 0
            return y
        end

        @test_throws BorrowCheckError _bc_copy_aliases_bad()

        mutable struct _BCIterateWeird
            x::Vector{Int}
        end

        Base.iterate(w::_BCIterateWeird) = (push!(getfield(w, :x), 1); (0, w))
        Base.iterate(::_BCIterateWeird, _) = nothing

        BorrowChecker.Auto.@auto function _bc_iterate_mutates_bad()
            w = _BCIterateWeird([1, 2, 3])
            y = w
            iterate(w)  # calls overloaded iterate (mutates)
            return y
        end

        @test_throws BorrowCheckError _bc_iterate_mutates_bad()
    end

    @testset "macro signature parsing: varargs" begin
        @auto function _bc_varargs_signature(xs...)
            return 0
        end
        @test _bc_varargs_signature() == 0
        @test _bc_varargs_signature(1) == 0
        @test _bc_varargs_signature(1, 2) == 0
    end

    @testset "macro signature parsing: default args" begin
        @auto function _bc_default_arg_signature(x=1)
            return x + 1
        end

        @test _bc_default_arg_signature() == 2
    end

    @testset "macro signature parsing: keyword-only signature" begin
        @auto function _bc_keyword_only_signature(; x, y)
            return x + y
        end

        @test _bc_keyword_only_signature(; x=1, y=2) == 3
    end

    @testset "macro signature parsing: anonymous typed arg" begin
        @auto function _bc_anon_typed_arg_signature(x, ::Type{T}=Int) where {T}
            return T
        end

        @test _bc_anon_typed_arg_signature(1) == Int
        @test _bc_anon_typed_arg_signature(1, Float64) == Float64
    end

    @testset "macro signature parsing: destructuring arg" begin
        @auto function _bc_destructure_signature((a, b))
            return a + b
        end

        @test _bc_destructure_signature((1, 2)) == 3
    end

    @testset "macro signature parsing: where + return type" begin
        @auto function _bc_where_ret_signature(x::T)::T where {T}
            return x
        end

        @test _bc_where_ret_signature(1) == 1
    end

    @testset "macro signature parsing: functor call method" begin
        struct _BCFun end

        @auto (f::_BCFun)(x) = x + 1

        @test _BCFun()(1) == 2
    end

    @testset "macro signature parsing: dotted function name" begin
        struct _BCAutoDotT end

        BorrowChecker.Auto.@auto function Base.identity(x::_BCAutoDotT)
            return x
        end

        @test Base.identity(_BCAutoDotT()) isa _BCAutoDotT
    end

    @testset "boxed captured variable: getproperty field type refinement" begin
        struct _BCBoxedField
            n::Int
        end

        @auto function _bc_boxed_getproperty_dim(x::_BCBoxedField)
            g = () -> getfield(x, :n)
            x = fakewrite(x)  # capture + assign forces Core.Box lowering
            a = zeros(Float64, getfield(x, :n))
            return (g(), length(a))
        end

        @test begin
            try
                _bc_boxed_getproperty_dim(_BCBoxedField(3)) == (3, 3)
            catch
                false
            end
        end
    end

    @testset "boxed captured variable: broadcast materialize should not consume" begin
        struct _BCBoxedBroadcast
            n::Int
        end

        @auto function _bc_boxed_broadcast_ok(x::_BCBoxedBroadcast)
            g = () -> getfield(x, :n)
            x = fakewrite(x)  # capture + assign forces Core.Box lowering
            b = rand(getfield(x, :n)) .< 0.5
            return (g(), sum(b))
        end

        @test begin
            try
                (n, s) = _bc_boxed_broadcast_ok(_BCBoxedBroadcast(10))
                n == 10 && s isa Real
            catch
                false
            end
        end
    end

    @testset "Threads.@threads plumbing should not spuriously consume" begin
        struct _BCThreadsBoxedRange
            n::Int
        end

        @auto function _bc_threads_boxed_range_ok(x::_BCThreadsBoxedRange, flag::Bool)
            g = () -> getfield(x, :n)
            x = fakewrite(x)  # capture + assign forces Core.Box lowering

            r = 1:(getfield(x, :n))
            if flag
                Base.Threads.@threads for i in r
                    fakewrite(i)
                end
            else
                for i in r
                    fakewrite(i)
                end
            end

            return g()
        end

        @test_broken begin
            try
                _bc_threads_boxed_range_ok(_BCThreadsBoxedRange(5), false) == 5
            catch
                false
            end
        end
    end

    @testset "known failure: Array{Int,l}(x) with value l" begin
        @auto scope = :function function _bc_array_value_dim_ctor(x)
            l = 1
            return Array{Int,l}(x)
        end

        @test begin
            try
                _bc_array_value_dim_ctor([1]) == [1]
            catch
                false
            end
        end
    end

    @testset "@auto assignment instrumentation: store should not create fresh origins" begin
        mutable struct _BCProjectionS
            a::Vector{Int}
        end

        bump!(a::Vector{Int}) = (a[1] += 1; nothing)

        @auto function _bc_projection_store_ok(s::_BCProjectionS)
            a = copy(s.a)  # avoid aliasing `s.a` during mutation
            bump!(a)
            s.a = a
            return s.a[1]
        end

        @test _bc_projection_store_ok(_BCProjectionS([1, 2, 3])) == 2
    end

    @testset "@auto known effects: eachindex should not consume/escape" begin
        @auto function _bc_eachindex_ok(refs, constants)
            for i in eachindex(refs, constants)
                refs[i] = constants[i]
            end
            return refs
        end

        @test _bc_eachindex_ok([1, 2, 3], [4, 5, 6]) == [4, 5, 6]
    end

    @testset "@auto known effects: copy should not consume" begin
        @auto function _bc_copy_call_ok(x)
            y = copy(x)
            return (x, y)
        end

        (x, y) = _bc_copy_call_ok([1, 2, 3])
        @test x == [1, 2, 3]
        @test y == [1, 2, 3]
    end

    @testset "macro rejects non-function inputs" begin
        @test_throws LoadError eval(:(BorrowChecker.Auto.@auto begin
            x = 1
        end))
    end

    @testset "macro option parsing: Config overrides" begin
        BorrowChecker.Auto.@auto max_summary_depth = 1 function _bc_macro_opt_max_depth(x)
            return x
        end
        @test _bc_macro_opt_max_depth(1) == 1

        opt = BorrowChecker.Auto.Config().optimize_until
        @eval BorrowChecker.Auto.@auto(
            optimize_until = $opt, _bc_macro_opt_optimize_until(x) = x
        )
        @test _bc_macro_opt_optimize_until(2) == 2
    end

    @testset "@auto debug logging" begin
        using Test

        Base.@noinline _bc_dbg_localfun(x) = x

        @auto debug = true debug_callee_depth = 1 function _bc_dbg_fail(n::Int)
            x = zeros(Float64, n)
            x2 = _bc_dbg_localfun(x)
            y = x2
            x2[1] = 0.0
            return length(y)
        end

        BC_TEST_TIMINGS && println("[BC_DEBUG] case: dbg_fail depth=1 (begin)")
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                BC_TEST_TIMINGS &&
                    println("[BC_DEBUG] calling _bc_dbg_fail(3) (expect throw)")
                @test_throws BorrowCheckError _bc_dbg_fail(3)
                BC_TEST_TIMINGS && println("[BC_DEBUG] _bc_dbg_fail(3) threw as expected")
            end

            BC_TEST_TIMINGS && println("[BC_DEBUG] reading jsonl output (dbg_fail depth=1)")
            s = read(path, String)
            ir_lines = filter(
                l -> occursin("\"event\":\"auto_debug_ir\"", l),
                split(s, '\n'; keepempty=false),
            )
            @test occursin("\"event\":\"auto_debug_check\"", s)
            @test occursin("\"event\":\"auto_debug_violations\"", s)
            @test occursin("\"event\":\"auto_debug_summaries\"", s)
            @test occursin("_bc_dbg_localfun", s)
            @test any(l -> occursin("\"depth\":0", l), ir_lines)
            @test any(l -> occursin("\"depth\":1", l), ir_lines)
        end

        @auto debug = true debug_callee_depth = 0 function _bc_dbg_depth0(n::Int)
            x = zeros(Float64, n)
            x2 = _bc_dbg_localfun(x)
            y = x2
            x2[1] = 0.0
            return length(y)
        end

        BC_TEST_TIMINGS && println("[BC_DEBUG] case: dbg_depth0 depth=0 (begin)")
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                BC_TEST_TIMINGS &&
                    println("[BC_DEBUG] calling _bc_dbg_depth0(3) (expect throw)")
                _ = try
                    _bc_dbg_depth0(3)
                    nothing
                catch
                    nothing
                end
            end
            BC_TEST_TIMINGS &&
                println("[BC_DEBUG] reading jsonl output (dbg_depth0 depth=0)")
            s = read(path, String)
            ir_lines = filter(
                l -> occursin("\"event\":\"auto_debug_ir\"", l),
                split(s, '\n'; keepempty=false),
            )
            @test any(l -> occursin("\"depth\":0", l), ir_lines)
            @test !any(l -> occursin("\"depth\":1", l), ir_lines)
        end

        @auto debug = true debug_callee_depth = 0 function _bc_dbg_ok(x)
            return x + 1
        end
        BC_TEST_TIMINGS && println("[BC_DEBUG] case: dbg_ok (begin)")
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                BC_TEST_TIMINGS && println("[BC_DEBUG] calling _bc_dbg_ok(1)")
                @test _bc_dbg_ok(1) == 2
            end
            BC_TEST_TIMINGS && println("[BC_DEBUG] reading jsonl output (dbg_ok)")
            s = read(path, String)
            @test occursin("\"event\":\"auto_debug_check\"", s) &&
                occursin("\"ok\":true", s)
            @test !occursin("\"event\":\"auto_debug_error\"", s)
        end

        # Warning + default-path behavior when env var is unset.
        BC_TEST_TIMINGS && println("[BC_DEBUG] case: warn default-path (begin)")
        default_path = joinpath(tempdir(), "BorrowChecker.auto.debug.$(getpid()).jsonl")
        rm(default_path; force=true)
        old = pop!(ENV, "BORROWCHECKER_AUTO_DEBUG_PATH", nothing)
        logs, _ = Test.collect_test_logs() do
            try
                BC_TEST_TIMINGS &&
                    println("[BC_DEBUG] calling _bc_dbg_depth0(3) with env unset (1)")
                _bc_dbg_depth0(3)
            catch
            end
            try
                BC_TEST_TIMINGS &&
                    println("[BC_DEBUG] calling _bc_dbg_depth0(3) with env unset (2)")
                _bc_dbg_depth0(3)
            catch
            end
        end
        old === nothing || (ENV["BORROWCHECKER_AUTO_DEBUG_PATH"] = old)
        @test count(
            lr ->
                lr.level == Base.CoreLogging.Warn && occursin(
                    "BorrowChecker.@auto debug enabled; writing JSONL debug log to",
                    lr.message,
                ),
            logs,
        ) == 1
        @test isfile(default_path)

        # Exercise the error-swallowing path in debug logging by pointing the log path to a directory.
        BC_TEST_TIMINGS && println("[BC_DEBUG] case: debug path is directory (begin)")
        mktempdir() do d
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => d) do
                @test _bc_dbg_ok(1) == 2
            end
        end

        # `optimize_until` is logged exactly as provided.
        BC_TEST_TIMINGS && println("[BC_DEBUG] case: invalid optimize_until logged (begin)")
        @auto debug = true optimize_until = "definitely_invalid_pass" function _bc_dbg_bad_opt(
            x
        )
            return x + 1
        end
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                BC_TEST_TIMINGS &&
                    println("[BC_DEBUG] calling _bc_dbg_bad_opt(1) (expect error logged)")
                _ = try
                    _bc_dbg_bad_opt(1)
                    nothing
                catch
                    nothing
                end
            end
            BC_TEST_TIMINGS &&
                println("[BC_DEBUG] reading jsonl output (invalid optimize_until)")
            s = read(path, String)
            @test occursin("\"event\":\"auto_debug_check\"", s)
            @test occursin("\"optimize_until\":\"definitely_invalid_pass\"", s)
            @test occursin("\"error\":", s)
            @test occursin("\"time_s\":", s)
        end

        # Summary exceptions are logged (best-effort) rather than crashing debug mode.
        @generated _bc_dbg_badgen(x) = error("boom")
        @auto debug = true scope = :function function _bc_dbg_summary_exception(x)
            return _bc_dbg_badgen(x)
        end
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                _ = try
                    _bc_dbg_summary_exception(Int[1])
                    nothing
                catch
                    nothing
                end
            end
            s = read(path, String)
            @test occursin("\"event\":\"auto_debug_summary_exception\"", s)
        end

        # Type refinement debug event is emitted when refinement makes changes.
        @auto debug = true scope = :function function _bc_dbg_refine_types_event()
            x = (g = () -> 3; g())
            return x
        end
        mktemp() do path, io
            close(io)
            withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => path) do
                _bc_dbg_refine_types_event()
            end
            s = read(path, String)
            @test occursin("\"event\":\"auto_debug_refine_types\"", s)
        end
    end

    @testset "scope=:none disables @auto" begin
        # This would normally fail borrow checking due to aliasing + mutation.
        BorrowChecker.Auto.@auto scope = :none function _bc_auto_disabled()
            x = [1, 2, 3]
            y = fakewrite(x)
            x[1] = 0
            return y
        end
        @test _bc_auto_disabled() == [0, 2, 3]
    end

    @testset "callable structs: good/bad for mutable/immutable" begin
        mutable struct _BCMutCallable
            n::Int
        end
        (f::_BCMutCallable)() = (f.n += 1; f.n)
        (f::_BCMutCallable)(::Val{:peek}) = f.n

        struct _BCImmCallable
            v::Vector{Int}
        end
        (f::_BCImmCallable)() = (f.v[1] += 1; f.v[1])
        (f::_BCImmCallable)(::Val{:peek}) = f.v

        # Mutable functor: updated when called => should error if an alias is live.
        @auto function _bc_mut_callable_bad()
            f = _BCMutCallable(0)
            g = f
            f()
            return g.n
        end
        @test_throws BorrowCheckError _bc_mut_callable_bad()

        # Mutable functor: read-only call => should be OK even with an alias.
        @auto function _bc_mut_callable_good()
            f = _BCMutCallable(0)
            g = f
            f(Val(:peek))
            return g.n
        end
        @test _bc_mut_callable_good() == 0

        # Immutable functor: can still mutate reachable state (e.g. a Vector field).
        @auto function _bc_imm_callable_bad()
            f = _BCImmCallable([0])
            g = f
            f()
            return g.v
        end
        @test_throws BorrowCheckError _bc_imm_callable_bad()

        # Immutable functor: read-only call should be OK even with an alias.
        @auto function _bc_imm_callable_good()
            f = _BCImmCallable([0])
            g = f
            f(Val(:peek))
            return g.v
        end
        @test _bc_imm_callable_good() == [0]
    end

    @testset "@generated callee mutation is detected" begin
        Base.@noinline @generated function _bc_gen_my_push!(x, v)
            return :(Base.push!(x, v))
        end

        @auto function _bc_generated_mutation_bad()
            x = [1, 2, 3]
            y = x
            _bc_gen_my_push!(x, 4)
            return y
        end

        @test_throws BorrowCheckError _bc_generated_mutation_bad()
    end

    @testset "checked-cache respects cfg (scope affects recursion)" begin
        # Repro: if `f` is checked once with `scope=:function`, then later recursion into `f`
        # under `scope=:module` must not be skipped due to a tt/world-only cache key.
        m = Module(gensym(:BCCacheCfg))
        Core.eval(m, :(import BorrowChecker as BC))
        Core.eval(
            m,
            quote
                function inner_bad()
                    x = [1, 2, 3]
                    f = () -> x
                    push!(x, 4)
                    return f
                end

                BC.@auto scope = :function f() = inner_bad()
                BC.@auto scope = :module g() = f()
            end,
        )

        # Warm the checked-cache for `f` under scope=:function (no recursion).
        @test m.f()() == [1, 2, 3, 4]
        # Now `g`'s recursive checking should re-check `f` under scope=:module and fail.
        @test_throws BorrowCheckError m.g()
    end

    @testset "scope=:module catches unannotated callee with closure alias" begin
        m = Module(gensym(:BCModuleScope))
        Core.eval(m, :(import BorrowChecker as BC))
        Core.eval(
            m,
            quote
                function foo()
                    x = [1, 2, 3]
                    f = () -> x
                    push!(x, 4)
                    return f
                end
            end,
        )
        Core.eval(m, :(BC.@auto scope = :module bar() = foo()))

        @test_throws BorrowCheckError m.bar()
    end

    @testset "scope=:module recurses into Base extension methods" begin
        # Repro: methods defined in the current module for Base functions (e.g. getindex)
        # should be considered "in-module" for `scope=:module` recursion.
        m = Module(gensym(:BCBaseExtScope))
        Core.eval(m, :(import BorrowChecker as BC))
        Core.eval(
            m,
            quote
                struct T end

                function Base.getindex(::T)
                    x = [1, 2, 3]
                    f = () -> x
                    push!(x, 4)
                    return f
                end

                BC.@auto scope = :module outer() = (T())[]
            end,
        )

        @test_throws BorrowCheckError m.outer()
    end

    @testset "macro one-line method parsing: where clause" begin
        BorrowChecker.Auto.@auto _bc_oneliner_where(x::T) where {T} = x
        @test _bc_oneliner_where(1) == 1
    end

    @testset "macro one-line method parsing: return type" begin
        BorrowChecker.Auto.@auto _bc_oneliner_ret(x)::Int = x
        @test _bc_oneliner_ret(1) == 1
    end

    @testset "lambda arglist: single argument" begin
        @auto function _bc_lambda_arglist_symbol()
            f = x -> x + 1
            return f(1)
        end

        @test _bc_lambda_arglist_symbol() == 2
    end

    @testset "lambda arglist: args_expr === nothing" begin
        # This form doesn't occur from the surface syntax, but older/lower-level
        # IR can contain lambdas represented as `Expr(:(->), nothing, body)`.
        # Ensure our lambda instrumentation handles it.
        fexpr = Expr(:(->), nothing, :(1))

        eval(
            quote
                BorrowChecker.Auto.@auto function _bc_lambda_arglist_nothing()
                    f = $fexpr
                    return f()
                end
            end,
        )

        @test _bc_lambda_arglist_nothing() == 1
    end

    @testset "instrumentation leaves quoted code alone" begin
        @auto function _bc_quote_expr()
            q = quote
                x = 1
            end
            return q isa Expr
        end

        @test _bc_quote_expr()
    end

    @testset "nested function definitions are instrumented" begin
        BorrowChecker.Auto.@auto function _bc_nested_function_bad()
            function _bc_inner()
                x = [1, 2, 3]
                y = x
                x[1] = 0
                return y
            end
            return _bc_inner()
        end

        @test_throws BorrowCheckError _bc_nested_function_bad()
    end

    @testset "local one-line method definitions are instrumented" begin
        BorrowChecker.Auto.@auto function _bc_local_oneliner_bad()
            _bc_inner() = begin
                x = [1, 2, 3]
                y = x
                x[1] = 0
                return y
            end
            return _bc_inner()
        end

        @test_throws BorrowCheckError _bc_local_oneliner_bad()
    end

    @testset "LinearAlgebra in-place ops" begin
        # Vector scaling (BLAS foreigncall) should be treated as a write.
        @auto function _bc_la_scal_ok()
            x = rand(3)
            y = copy(x)
            LinearAlgebra.BLAS.scal!(2.0, y)
            return y
        end
        @test length(_bc_la_scal_ok()) == 3

        @auto function _bc_la_scal_bad()
            x = rand(3)
            y = x
            LinearAlgebra.BLAS.scal!(2.0, x)
            # Use both bindings after the mutation so the alias is live.
            return y
        end
        @test_throws BorrowCheckError _bc_la_scal_bad()

        @auto function _bc_la_triu_ok()
            A = [1.0 2.0 3.0; 4.0 5.0 6.0; 7.0 8.0 9.0]
            B = copy(A)
            LinearAlgebra.triu!(B)
            return B
        end
        @test _bc_la_triu_ok()[2, 1] == 0.0

        @auto function _bc_la_triu_bad()
            A = [1.0 2.0 3.0; 4.0 5.0 6.0; 7.0 8.0 9.0]
            B = A
            LinearAlgebra.triu!(A)
            return (A, B)
        end
        @test_throws BorrowCheckError _bc_la_triu_bad()
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

    @testset "kwcall unknown-call consume expands to keyword values" begin
        fkw_nothing(; x, y) = nothing

        @auto function _bc_kwcall_unknown_consume_should_error(vf)
            x = [1, 2, 3]
            y = x
            g = only(vf)
            g(; x=x, y=y)
            return y
        end

        @test_throws BorrowCheckError _bc_kwcall_unknown_consume_should_error(
            Any[fkw_nothing]
        )
    end

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

    @testset "foreigncall treated as write (uniqueness enforced)" begin
        @auto function _bc_foreigncall_bad(flag::Bool)
            x = [1, 2, 3]
            y = x
            if flag
                ccall(:jl_typeof_str, Cstring, (Any,), x)
            end
            return y
        end

        @auto function _bc_foreigncall_ok(flag::Bool)
            x = [1, 2, 3]
            if flag
                ccall(:jl_typeof_str, Cstring, (Any,), x)
            end
            return x
        end

        @test_throws BorrowCheckError _bc_foreigncall_bad(false)
        @test _bc_foreigncall_ok(false) == [1, 2, 3]
    end

    @testset "_collect_ssa_ids! handles IR node objects (coverage)" begin
        # This is a real `:foreigncall` that embeds Core IR node objects as *constants*
        # inside a tuple argument. The borrow checker doesn't care about these values,
        # but the foreigncall backslice should traverse them without error.
        #
        # This exercises `_collect_ssa_ids!` branches for:
        # - `Core.ReturnNode` (val)
        # - `Core.PiNode` (val)
        # - `Core.UpsilonNode` (val)
        # - `Core.GotoIfNot` (cond)
        # - `Tuple` recursion
        @auto function _bc_foreigncall_node_constants_ok()
            ccall(
                :jl_typeof_str,
                Cstring,
                (Any,),
                (
                    Core.ReturnNode(Core.SSAValue(0)),
                    Core.PiNode(Core.SSAValue(0), Any),
                    Core.UpsilonNode(Core.SSAValue(0)),
                    Core.GotoIfNot(Core.SSAValue(0), 1),
                    (Core.SSAValue(0),),
                ),
            )
            return nothing
        end

        @test _bc_foreigncall_node_constants_ok() === nothing
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

    @testset "Tasks are shareable handles (do not trigger move/escape errors)" begin
        @auto function _bc_async_handle_ok()
            t = @async 1
            return fetch(t)
        end

        @test _bc_async_handle_ok() == 1

        @auto function _bc_async_copy_after_spawn_bad()
            x = [1, 2, 3]
            t = @async begin
                push!(x, 4)
                return sum(x)
            end
            y = copy(x)  # unsafe: task may mutate `x` before this copy happens
            return fetch(t), y
        end

        @test_throws BorrowCheckError _bc_async_copy_after_spawn_bad()

        @auto function _bc_async_copy_before_spawn_ok()
            x = [1, 2, 3]
            y = copy(x)
            t = @async begin
                push!(x, 4)
                return sum(x)
            end
            return fetch(t), y
        end

        @test _bc_async_copy_before_spawn_ok() == (10, [1, 2, 3])
    end

    @testset "Atomics are shareable handles (aliasing is allowed)" begin
        @auto function _bc_atomic_alias_ok()
            a = Threads.Atomic{Int}(0)
            b = a
            Threads.atomic_add!(a, 1)
            return b[]
        end

        @test _bc_atomic_alias_ok() == 1
    end

    @testset "__bc_assert_safe__ short-circuits on cache hit" begin
        local_f(x) = x
        tt = Tuple{typeof(local_f),Int}

        BorrowChecker.Auto.__bc_assert_safe__(tt)
        GC.gc()

        alloc = @allocated BorrowChecker.Auto.__bc_assert_safe__(tt)
        @test alloc < 200_000
    end

    @testset "__bc_assert_safe__ thread-safety" begin
        Threads.nthreads() < 2 && return nothing

        Base.@lock BorrowChecker.Auto.CHECKED_CACHE begin
            empty!(BorrowChecker.Auto.CHECKED_CACHE[])
        end

        fs = [
            (x::Int) -> x,
            (x::Int) -> x + 1,
            (x::Int) -> x + 2,
            (x::Int) -> x + 3,
            (x::Int) -> x + 4,
            (x::Int) -> x + 5,
            (x::Int) -> x + 6,
            (x::Int) -> x + 7,
            (x::Int) -> x + 8,
            (x::Int) -> x + 9,
        ]
        tts = map(f -> Tuple{typeof(f),Int}, fs)

        turn1 = Channel{Int}(1)
        turn2 = Channel{Int}(1)
        done = Channel{Int}(1) # idx

        function worker(which::Int)
            turn = (which == 1) ? turn1 : turn2
            for _ in 1:length(tts)
                idx = take!(turn)
                BorrowChecker.Auto.__bc_assert_safe__(tts[idx])
                put!(done, idx)
            end
            return nothing
        end

        task1 = Threads.@spawn worker(1)
        task2 = Threads.@spawn worker(2)

        for i in 1:length(tts)
            first = isodd(i) ? 1 : 2
            second = (first == 1) ? 2 : 1

            put!((first == 1) ? turn1 : turn2, i)
            @test take!(done) == i

            put!((second == 1) ? turn1 : turn2, i)
            @test take!(done) == i
        end

        wait(task1)
        wait(task2)

        # Free-for-all: lots of concurrent hits/misses should not throw or deadlock.
        Base.@lock BorrowChecker.Auto.CHECKED_CACHE begin
            empty!(BorrowChecker.Auto.CHECKED_CACHE[])
        end

        nworkers = 16
        jobs = 60
        errs = Channel{Any}(nworkers)
        @sync for _ in 1:nworkers
            Threads.@spawn begin
                err = nothing
                try
                    for j in 1:jobs
                        BorrowChecker.Auto.__bc_assert_safe__(tts[(j % length(tts)) + 1])
                    end
                catch e
                    err = e
                end
                put!(errs, err)
            end
        end
        for _ in 1:nworkers
            e = take!(errs)
            e === nothing || rethrow(e)
        end
    end

    @testset "@auto scope=:module recursive callees" begin
        # Without recursion, this outer method doesn't observe the inner violation.
        Base.@noinline function _bc_scope_inner_bad()
            x = [1, 2, 3]
            y = fakewrite(x)
            x[1] = 0
            return y
        end

        @auto function _bc_scope_outer_norec_ok()
            return _bc_scope_inner_bad()
        end
        @test _bc_scope_outer_norec_ok() == [0, 2, 3]

        @auto scope = :module function _bc_scope_outer_rec_bad()
            return _bc_scope_inner_bad()
        end
        @test_throws BorrowCheckError _bc_scope_outer_rec_bad()
    end

    @testset "modules are not owned (avoid spurious consumes)" begin
        @auto function _bc_module_not_owned()
            m = Base
            g = Base.inferencebarrier(identity)
            g(m) # unknown/dynamic call site should NOT consume `m`
            return getproperty(m, :Math)
        end

        @test _bc_module_not_owned() === Base.Math
    end

    @testset "isa is pure (does not consume)" begin
        @auto function _bc_isa_does_not_consume()
            x = [1, 2, 3]
            y = fakewrite(x)
            if y isa Vector{Int}
                y[1] = 0
                return y
            else
                error("unexpected")
            end
        end

        @test _bc_isa_does_not_consume() == [0, 2, 3]
    end

    @testset "scope=:user excludes Core/Base recursion" begin
        cfg = BorrowChecker.Auto.Config(; scope=:user)
        @test BorrowChecker.Auto._scope_allows_module(Core, cfg) == false
        @test BorrowChecker.Auto._scope_allows_module(Base, cfg) == false
        @test BorrowChecker.Auto._scope_allows_module(Main, cfg) == true

        @static if isdefined(Core, :Compiler)
            @test BorrowChecker.Auto._scope_allows_module(Core.Compiler, cfg) == false
        end
        @static if isdefined(Base, :Iterators)
            @test BorrowChecker.Auto._scope_allows_module(Base.Iterators, cfg) == false
        end
    end

    @testset "scope=:all does not crash on PhiCNode" begin
        @auto scope = :all _bc_scope_all_sin(x) = sin(x)
        err = try
            _bc_scope_all_sin(1.0)
            nothing
        catch e
            e
        end
        @test isnothing(err)
    end

    @testset "Core.throw_inexacterror does not BorrowCheckError" begin
        # This should throw an `InexactError` at runtime, but borrow checking (including
        # recursive checking of user code) should not fail.
        @auto scope = :user _bc_inexact_int64(x::UInt64) = Int64(x)
        @test_throws InexactError _bc_inexact_int64(typemax(UInt64))
    end

    @testset "summary cache determinism" begin
        Base.@lock BorrowChecker.Auto.SUMMARY_STATE begin
            empty!(BorrowChecker.Auto.SUMMARY_STATE[].summary_cache)
            empty!(BorrowChecker.Auto.SUMMARY_STATE[].tt_summary_cache)
            empty!(BorrowChecker.Auto.SUMMARY_STATE[].summary_inprogress)
            empty!(BorrowChecker.Auto.SUMMARY_STATE[].tt_summary_inprogress)
        end

        deep1(x) = x
        deep2(x) = deep1(x)
        deep3(x) = deep2(x)

        cfg = BorrowChecker.Auto.Config(; max_summary_depth=2)
        tt = Tuple{typeof(deep3),Vector{Int}}

        BorrowChecker.Auto._summary_for_tt(tt, cfg; depth=cfg.max_summary_depth)

        function latest_entry()
            Base.@lock BorrowChecker.Auto.SUMMARY_STATE begin
                best_key = nothing
                for k in keys(BorrowChecker.Auto.SUMMARY_STATE[].tt_summary_cache)
                    (k[1] === tt && k[3] == cfg) || continue
                    (best_key === nothing || k[2] > best_key[2]) && (best_key = k)
                end
                best_key === nothing && error("missing cache entry")
                return BorrowChecker.Auto.SUMMARY_STATE[].tt_summary_cache[best_key]
            end
        end

        entry1 = latest_entry()
        @test entry1.over_budget == true

        BorrowChecker.Auto._summary_for_tt(tt, cfg; depth=0)
        entry2 = latest_entry()
        @test entry2.over_budget == false
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

    @testset "Pointer intrinsics + known issues" begin
        @auto function _bc_pointerset_ok()
            A = [1, 2, 3]
            p = pointer(A)
            unsafe_store!(p, 99, 1)
            return nothing
        end
        @test _bc_pointerset_ok() === nothing

        @auto function _bc_pointer_unsafe_store_regression()
            A = [1, 2, 3]
            B = A
            p = pointer(A)
            unsafe_store!(p, 99, 1)
            return B
        end
        @test_throws BorrowCheckError _bc_pointer_unsafe_store_regression()

        @auto function _bc_pointerset_alias_bad()
            A = [1, 2, 3]
            p = pointer(A)
            q = p
            unsafe_store!(p, 99, 1)
            return q
        end
        @test_throws BorrowCheckError _bc_pointerset_alias_bad()

        @auto function _bc_reinterpret_write_bad()
            A = Int32[1, 2, 3, 4]
            B = A
            R = reinterpret(UInt8, A) # shares memory with A
            R[1] = 0x7f
            return B
        end
        @test_throws BorrowCheckError _bc_reinterpret_write_bad()
    end

    @testset "Tuple duplicates aliasing" begin
        @auto function _bc_return_tuple_copy_order_bad(x)
            return (x, copy(x))
        end
        @test_throws BorrowCheckError _bc_return_tuple_copy_order_bad([1, 2, 3])

        @auto function _bc_return_tuple_copy_order_ok(x)
            return (copy(x), x)
        end
        a, b = _bc_return_tuple_copy_order_ok([1, 2, 3])
        @test a == b == [1, 2, 3]

        @auto function _bc_return_tuple_duplicates_bad()
            x = [1, 2, 3]
            return (x, x)
        end
        @test_throws BorrowCheckError _bc_return_tuple_duplicates_bad()

        @auto function _bc_array_literal_duplicates_bad()
            x = [1, 2, 3]
            return [x, x]
        end
        @test_throws BorrowCheckError _bc_array_literal_duplicates_bad()

        @auto function _bc_array_literal_copy_order_bad(x)
            return [x, copy(x)]
        end
        @test_throws BorrowCheckError _bc_array_literal_copy_order_bad([1, 2, 3])

        @auto function _bc_array_literal_copy_order_ok(x)
            return [copy(x), x]
        end
        ys = _bc_array_literal_copy_order_ok([1, 2, 3])
        @test ys[1] == ys[2] == [1, 2, 3]
    end

    @testset "Known foreigncall effects" begin
        @testset "jl_genericmemory_copyto writes destination only" begin
            @auto scope = :all _bc_wrap_in_vec(x) = [x]
            @test _bc_wrap_in_vec([1, 2, 3]) == [[1, 2, 3]]
        end

        @testset "BoundsError constructor is treated as pure" begin
            @auto scope = :all _bc_sin(x) = sin(x)
            @test _bc_sin(1.0) == sin(1.0)
        end
    end

    @testset "Core._typevar does not consume" begin
        @auto scope = :all _bc_mk_typevar() = (TypeVar(:T, Int); true)
        @test _bc_mk_typevar()
    end

    @testset "read-only Base foreigncalls" begin
        @testset "jl_object_id" begin
            @auto scope = :all function _bc_objectid_alias_ok(x)
                y = x
                objectid(x)
                return x === y
            end
            v = Any[1]
            @test _bc_objectid_alias_ok(v)
        end

        @testset "jl_type_hash" begin
            @auto scope = :all function _bc_hash_type_alias_ok(T)
                S = T
                hash(T)
                return T === S
            end
            @test _bc_hash_type_alias_ok(Int)
        end

        @testset "jl_type_unionall" begin
            @auto scope = :all function _bc_unionall_typearg_alias_ok(t)
                u = t
                UnionAll(TypeVar(:T), t)
                return t === u
            end
            @test _bc_unionall_typearg_alias_ok(Int)
        end

        @testset "jl_eqtable_get" begin
            @auto scope = :all function _bc_iddict_get_alias_ok(d, k)
                d2 = d
                get(d, k, nothing)
                return d === d2
            end
            key = Any[1]
            d = IdDict{Any,Any}(key => 2)
            @test _bc_iddict_get_alias_ok(d, key)
        end

        @testset "jl_eqtable_nextind (via iterate)" begin
            @auto scope = :all function _bc_iddict_iterate_alias_ok(d)
                d2 = d
                iterate(d)
                return d === d2
            end
            d = IdDict{Any,Any}(Any[1] => 2)
            @test _bc_iddict_iterate_alias_ok(d)
        end

        @testset "jl_get_fieldtypes" begin
            @auto scope = :all function _bc_fieldtypes_alias_ok(T)
                S = T
                fieldtypes(T)
                return T === S
            end
            @test _bc_fieldtypes_alias_ok(ComplexF64)
        end

        @testset "jl_field_index" begin
            @auto scope = :all function _bc_fieldindex_alias_ok(T)
                S = T
                Base.fieldindex(T, :re, true)
                return T === S
            end
            @test _bc_fieldindex_alias_ok(ComplexF64)
        end

        @testset "jl_gc_new_weakref_th" begin
            @auto scope = :all function _bc_weakref_alias_ok(x)
                y = x
                WeakRef(x)
                return x === y
            end
            v = Any[1]
            @test _bc_weakref_alias_ok(v)
        end

        @testset "jl_value_ptr" begin
            @auto scope = :all function _bc_ptr_from_objref_alias_ok(x)
                y = x
                pointer_from_objref(x)
                return x === y
            end
            v = Any[1]
            @test _bc_ptr_from_objref_alias_ok(v)
        end
    end

    @testset "Known effects registry only uses Core" begin
        allowed_auto = Set{Any}([BorrowChecker.Auto.Config, BorrowChecker.Auto.__bc_bind__])
        if isdefined(BorrowChecker.Auto, :__bc_assert_safe__)
            push!(allowed_auto, BorrowChecker.Auto.__bc_assert_safe__)
        end

        bad = Any[]
        for f in BC_BUILTIN_EFFECT_KEYS
            m = try
                parentmodule(f)
            catch
                nothing
            end

            if m === BorrowChecker.Auto
                (f in allowed_auto) || push!(bad, (f, m))
                continue
            end

            (m === Core || m === Core.Intrinsics) || push!(bad, (f, m))
        end

        @test isempty(bad)
    end

    if (@isdefined(_bc_timing_ts)) && _bc_timing_ts !== nothing
        using Test
        Test.pop_testset()
        # Don't print the full nested summary; we only want the timing lines above.
        Test.finish(_bc_timing_ts; print_results=false)
    end
end
