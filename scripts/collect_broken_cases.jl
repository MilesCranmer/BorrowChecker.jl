#!/usr/bin/env julia

import Pkg

Pkg.activate(@__DIR__; io=devnull)
Pkg.develop(Pkg.PackageSpec(; path=abspath(joinpath(@__DIR__, ".."))); io=devnull)
Pkg.instantiate(; io=devnull)

using Dates
using TOML

using BorrowChecker
using DynamicExpressions

function _arg_value(args::Vector{String}, flag::String, default::Union{Nothing,String}=nothing)
    for i in 1:length(args)
        if args[i] == flag
            return (i < length(args)) ? args[i + 1] : default
        end
    end
    return default
end

function _required_arg(args::Vector{String}, flag::String)::String
    v = _arg_value(args, flag, nothing)
    v === nothing && error("Missing required argument: $flag")
    return v
end

function _first_line_matching(path::String, needle::AbstractString)
    i = 0
    for ln in eachline(path)
        i += 1
        occursin(needle, ln) && return i
    end
    return nothing
end

function _nearest_testset_name(path::String, line::Int)
    lines = readlines(path)
    i = min(line, length(lines))
    while i >= 1
        m = match(r"@testset\\s+\"([^\"]+)\"", lines[i])
        m === nothing || return m.captures[1]
        i -= 1
    end
    return nothing
end

function _event_counts(jsonl_path::String)
    isfile(jsonl_path) || return Dict{String,Int}()
    counts = Dict{String,Int}()
    for ln in eachline(jsonl_path)
        m = match(r"\"event\":\"([^\"]+)\"", ln)
        m === nothing && continue
        ev = m.captures[1]
        counts[ev] = get(counts, ev, 0) + 1
    end
    return counts
end

function _violation_dicts(err)
    err isa BorrowChecker.Auto.BorrowCheckError || return Any[]
    out = Any[]
    for v in err.violations
        file, line = if v.lineinfo === nothing
            (nothing, nothing)
        else
            try
                BorrowChecker.Auto._lineinfo_file_line(v.lineinfo)
            catch
                (nothing, nothing)
            end
        end
        d = Dict{String,Any}("idx" => v.idx, "msg" => v.msg, "stmt" => string(v.stmt))
        file === nothing || (d["file"] = file)
        line === nothing || (d["line"] = line)
        push!(out, d)
    end
    return out
end

function _toml_dict(pairs::Pair...)
    d = Dict{String,Any}()
    for (k, v) in pairs
        v === nothing && continue
        d[string(k)] = v
    end
    return d
end

function run_case!(
    case_id::String;
    title::String,
    source_file::String,
    broken_marker_needle::String,
    invoke::Function,
    outdir::String,
)
    jsonl_dir = joinpath(outdir, "jsonl")
    meta_dir = joinpath(outdir, "meta")
    mkpath(jsonl_dir)
    mkpath(meta_dir)

    jsonl_path = joinpath(jsonl_dir, "$(case_id).jsonl")
    rm(jsonl_path; force=true)
    # Ensure the file exists even if no debug events are emitted (useful for tooling/reporting).
    open(jsonl_path, "w") do _io
    end

    err = nothing
    ret = nothing
    start = Dates.now(Dates.UTC)
    withenv("BORROWCHECKER_AUTO_DEBUG_PATH" => jsonl_path) do
        try
            ret = invoke()
        catch e
            err = e
        end
    end
    stop = Dates.now(Dates.UTC)

    marker_line = _first_line_matching(source_file, broken_marker_needle)
    testset = marker_line === nothing ? nothing : _nearest_testset_name(source_file, marker_line)

    counts = _event_counts(jsonl_path)
    ok = (err === nothing)
    meta = _toml_dict(
        "case_id" => case_id,
        "title" => title,
        "source_file" => source_file,
        "broken_marker_needle" => broken_marker_needle,
        "broken_marker_line" => marker_line,
        "testset" => testset,
        "julia_version" => string(VERSION),
        "started_utc" => Dates.format(start, dateformat"yyyy-mm-ddTHH:MM:SS"),
        "finished_utc" => Dates.format(stop, dateformat"yyyy-mm-ddTHH:MM:SS"),
        "ok" => ok,
        "return_value" => (ok ? string(ret) : nothing),
        "error_type" => (ok ? nothing : string(typeof(err))),
        "error" => (ok ? nothing : sprint(showerror, err)),
        "borrowcheck_error" => (err isa BorrowChecker.Auto.BorrowCheckError),
        "violation_count" =>
            (err isa BorrowChecker.Auto.BorrowCheckError ? length(err.violations) : 0),
        "violations" => _violation_dicts(err),
        "jsonl_path" => jsonl_path,
        "jsonl_bytes" => (isfile(jsonl_path) ? filesize(jsonl_path) : 0),
        "jsonl_event_counts" => counts,
        "debug_cfg" =>
            _toml_dict("debug" => true, "debug_callee_depth" => 2, "optimize_until" => "compact 1"),
    )

    open(joinpath(meta_dir, "$(case_id).toml"), "w") do io
        TOML.print(io, meta)
    end

    return meta
end

Base.@noinline fakewrite(x) = Base.inferencebarrier(x)

struct _BCBoxedField
    n::Int
end

struct _BCBoxedBroadcast
    n::Int
end

struct _BCThreadsBoxedRange
    n::Int
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_boxed_getproperty_dim(
    x::_BCBoxedField,
)
    g = () -> getfield(x, :n)
    x = fakewrite(x)
    a = zeros(Float64, getfield(x, :n))
    return (g(), length(a))
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_boxed_broadcast_ok(
    x::_BCBoxedBroadcast,
)
    g = () -> getfield(x, :n)
    x = fakewrite(x)
    b = rand(getfield(x, :n)) .< 0.5
    return (g(), sum(b))
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_threads_boxed_range_ok(
    x::_BCThreadsBoxedRange,
    flag::Bool,
)
    g = () -> getfield(x, :n)
    x = fakewrite(x)

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

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_array_value_dim_ctor(
    x,
)
    l = 1
    return Array{Int,l}(x)
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" bc_copy_ok(ex) =
    copy(ex)

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_lambda_arglist_symbol()
    f = x -> x + 1
    return f(1)
end

const _BC_LAMBDA_ARGLIST_NOTHING_EXPR = Expr(:(->), nothing, :(1))
eval(
    quote
        BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_lambda_arglist_nothing()
            f = $_BC_LAMBDA_ARGLIST_NOTHING_EXPR
            return f()
        end
    end,
)

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_nested_function_bad()
    function _bc_inner()
        x = [1, 2, 3]
        y = x
        x[1] = 0
        return y
    end
    return _bc_inner()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_local_oneliner_bad()
    _bc_inner() = begin
        x = [1, 2, 3]
        y = x
        x[1] = 0
        return y
    end
    return _bc_inner()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_bad_closure_body_0arg()
    f = () -> begin
        x = [1, 2, 3]
        y = x
        push!(x, 9)
        return y
    end
    return f()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_bad_closure_body_with_arg(
    z,
)
    f = () -> begin
        x = z
        y = x
        push!(x, 9)
        return y
    end
    return f()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_ok_closure_body_0arg()
    f = () -> begin
        x = [1, 2, 3]
        y = copy(x)
        push!(x, 9)
        return y
    end
    return f()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_ok_closure_body_with_arg(
    z,
)
    f = () -> begin
        x = copy(z)
        y = copy(x)
        push!(x, 9)
        return y
    end
    return f()
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_bad_view_alias()
    x = [1, 2, 3, 4]
    y = view(x, 1:2)
    push!(x, 9)
    return collect(y)
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_bad_closure_capture()
    x = [1, 2, 3]
    y = x
    f = () -> (push!(x, 9); nothing)
    f()
    return y
end

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_bad_closure_capture_nested()
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

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_ok_closure_capture_readonly()
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

BorrowChecker.Auto.@auto debug = true debug_callee_depth = 2 optimize_until = "compact 1" function _bc_module_not_owned()
    m = Base
    g = Base.inferencebarrier(identity)
    g(m)
    return getproperty(m, :Math)
end

function main()
    outdir = _required_arg(ARGS, "--outdir")
    mkpath(outdir)

    cases = Any[]

    push!(
        cases,
        run_case!(
            "auto_boxed_getproperty_dim";
            title="boxed captured variable: getproperty field type refinement",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="boxed captured variable: getproperty field type refinement",
            invoke=() -> _bc_boxed_getproperty_dim(_BCBoxedField(3)),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_boxed_broadcast_ok";
            title="boxed captured variable: broadcast materialize should not consume",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="boxed captured variable: broadcast materialize should not consume",
            invoke=() -> _bc_boxed_broadcast_ok(_BCBoxedBroadcast(10)),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_threads_boxed_range_ok";
            title="Threads.@threads plumbing should not spuriously consume",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="Threads.@threads plumbing should not spuriously consume",
            invoke=() -> _bc_threads_boxed_range_ok(_BCThreadsBoxedRange(5), false),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_array_value_dim_ctor";
            title="known failure: Array{Int,l}(x) with value l",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="known failure: Array{Int,l}(x) with value l",
            invoke=() -> _bc_array_value_dim_ctor([1]),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_lambda_arglist_symbol";
            title="lambda arglist: single argument",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="lambda arglist: single argument",
            invoke=_bc_lambda_arglist_symbol,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_lambda_arglist_nothing";
            title="lambda arglist: args_expr === nothing",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="lambda arglist: args_expr === nothing",
            invoke=_bc_lambda_arglist_nothing,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_nested_function_bad";
            title="nested function definitions are instrumented",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="nested function definitions are instrumented",
            invoke=_bc_nested_function_bad,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_local_oneliner_bad";
            title="local one-line method definitions are instrumented",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="local one-line method definitions are instrumented",
            invoke=_bc_local_oneliner_bad,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_bad_closure_body_0arg";
            title="_bc_bad_closure_body_0arg",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_bad_closure_body_0arg",
            invoke=_bc_bad_closure_body_0arg,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_bad_closure_body_with_arg";
            title="_bc_bad_closure_body_with_arg",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_bad_closure_body_with_arg",
            invoke=() -> _bc_bad_closure_body_with_arg([1, 2, 3]),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_ok_closure_body_0arg";
            title="_bc_ok_closure_body_0arg",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_ok_closure_body_0arg",
            invoke=_bc_ok_closure_body_0arg,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_ok_closure_body_with_arg";
            title="_bc_ok_closure_body_with_arg",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_ok_closure_body_with_arg",
            invoke=() -> _bc_ok_closure_body_with_arg([1, 2, 3]),
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_bad_view_alias";
            title="_bc_bad_view_alias",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_bad_view_alias",
            invoke=_bc_bad_view_alias,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_bad_closure_capture";
            title="_bc_bad_closure_capture",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_bad_closure_capture()",
            invoke=_bc_bad_closure_capture,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_bad_closure_capture_nested";
            title="_bc_bad_closure_capture_nested",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_bad_closure_capture_nested",
            invoke=_bc_bad_closure_capture_nested,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_ok_closure_capture_readonly";
            title="_bc_ok_closure_capture_readonly",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="_bc_ok_closure_capture_readonly",
            invoke=_bc_ok_closure_capture_readonly,
            outdir=outdir,
        ),
    )

    push!(
        cases,
        run_case!(
            "auto_module_not_owned";
            title="modules are not owned (avoid spurious consumes)",
            source_file=joinpath("test", "auto_borrow_checker_tests.jl"),
            broken_marker_needle="modules are not owned (avoid spurious consumes)",
            invoke=_bc_module_not_owned,
            outdir=outdir,
        ),
    )

    operators = OperatorEnum(1 => [exp], 2 => [+, -, *])
    x1 = Expression(Node{Float64}(; feature=1); operators)
    push!(
        cases,
        run_case!(
            "dynamic_expressions_copy_ok";
            title="DynamicExpressions: copy(::Expression) should not spuriously consume",
            source_file=joinpath("test", "dynamic_expressions_integration_tests.jl"),
            broken_marker_needle="BorrowChecker.Auto.@auto bc_copy_ok",
            invoke=() -> bc_copy_ok(x1),
            outdir=outdir,
        ),
    )

    open(joinpath(outdir, "summary.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "toolchain_label" => _arg_value(ARGS, "--label", ""),
                "julia_version" => string(VERSION),
                "finished_utc" => Dates.format(Dates.now(Dates.UTC), dateformat"yyyy-mm-ddTHH:MM:SS"),
                "cases" => cases,
            ),
        )
    end
end

main()
