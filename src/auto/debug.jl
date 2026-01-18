const AUTO_DEBUG_LOCK = ReentrantLock()

function _auto_debug_path(warn::Bool=false)
    p = get(ENV, "BORROWCHECKER_AUTO_DEBUG_PATH", "")
    if isempty(p)
        path = joinpath(tempdir(), "BorrowChecker.auto.debug.$(getpid()).jsonl")
        warn && @warn(
            "BorrowChecker.@auto debug enabled; writing JSONL debug log to $path",
            maxlog = 1,
        )
        return path
    end
    return p
end

function _auto_debug_write_json(io::IO, x)
    if x === nothing
        write(io, "null")
    elseif x === true
        write(io, "true")
    elseif x === false
        write(io, "false")
    elseif x isa Integer
        print(io, x)
    elseif x isa AbstractFloat
        print(io, x)
    elseif x isa AbstractString
        write(io, '"')
        for c in x
            if c == '"'
                write(io, "\\\"")
            elseif c == '\\'
                write(io, "\\\\")
            elseif c == '\n'
                write(io, "\\n")
            elseif c == '\r'
                write(io, "\\r")
            elseif c == '\t'
                write(io, "\\t")
            elseif c == '\b'
                write(io, "\\b")
            elseif c == '\f'
                write(io, "\\f")
            elseif Int(c) < 0x20
                print(io, "\\u", lpad(string(Int(c); base=16), 4, '0'))
            else
                write(io, c)
            end
        end
        write(io, '"')
    elseif x isa AbstractVector
        write(io, '[')
        first = true
        for v in x
            first || write(io, ',')
            first = false
            _auto_debug_write_json(io, v)
        end
        write(io, ']')
    elseif x isa AbstractDict
        write(io, '{')
        first = true
        for (k, v) in x
            first || write(io, ',')
            first = false
            _auto_debug_write_json(io, String(k))
            write(io, ':')
            _auto_debug_write_json(io, v)
        end
        write(io, '}')
    else
        _auto_debug_write_json(io, string(x))
    end
    return nothing
end

function _auto_debug_emit(cfg::Config, obj)
    lock(AUTO_DEBUG_LOCK) do
        try
            open(_auto_debug_path(), "a") do io
                _auto_debug_write_json(io, obj)
                write(io, '\n')
            end
        catch
        end
    end
    return nothing
end

function _auto_debug_effect_summary_dict(s::EffectSummary)
    return Dict(
        "writes" => collect(s.writes),
        "consumes" => collect(s.consumes),
        "ret_aliases" => collect(s.ret_aliases),
    )
end

function _auto_debug_cfg_dict(cfg::Config)
    return Dict(
        "optimize_until" => cfg.optimize_until,
        "max_summary_depth" => cfg.max_summary_depth,
        "scope" => String(cfg.scope),
        "debug" => cfg.debug,
        "debug_callee_depth" => cfg.debug_callee_depth,
    )
end

function _auto_debug_borrow_violation_dict(v::BorrowViolation)
    li = v.lineinfo
    file, line = if li === nothing
        (nothing, nothing)
    else
        try
            _lineinfo_file_line(li)
        catch
            (nothing, nothing)
        end
    end
    return Dict(
        "idx" => v.idx,
        "msg" => v.msg,
        "file" => file,
        "line" => line,
        "stmt" => string(v.stmt),
    )
end

function _auto_debug_summary_keys(world::UInt, cfg::Config)
    Base.@lock SUMMARY_STATE begin
        mi_keys = Set{Any}()
        tt_keys = Set{Any}()
        for k in keys(SUMMARY_STATE[].summary_cache)
            (k[2] == world && k[3] == cfg) && push!(mi_keys, k)
        end
        for k in keys(SUMMARY_STATE[].tt_summary_cache)
            (k[2] == world && k[3] == cfg) && push!(tt_keys, k)
        end
        return (mi_keys, tt_keys)
    end
end

function _auto_debug_collect_new_summaries(world::UInt, cfg::Config, snapshot)
    snapshot === nothing && return (Any[], Any[])
    (mi0, tt0) = snapshot
    new_mi = Any[]
    new_tt = Any[]

    @inline function push_new!(dest, kind::String, k, entry)
        push!(
            dest,
            Dict(
                "kind" => kind,
                "key" => string(k[1]),
                "depth" => entry.depth,
                "over_budget" => entry.over_budget,
                "summary" => _auto_debug_effect_summary_dict(entry.summary),
            ),
        )
        return nothing
    end

    Base.@lock SUMMARY_STATE begin
        for (k, entry) in SUMMARY_STATE[].summary_cache
            (k[2] == world && k[3] == cfg && !(k in mi0)) || continue
            push_new!(new_mi, "mi", k, entry)
        end
        for (k, entry) in SUMMARY_STATE[].tt_summary_cache
            (k[2] == world && k[3] == cfg && !(k in tt0)) || continue
            push_new!(new_tt, "tt", k, entry)
        end
    end
    return (new_mi, new_tt)
end

function _auto_debug_ir_string(ir::CC.IRCode)
    return sprint(show, ir)
end

function _auto_debug_emit_ir_for_tt(cfg::Config, world::UInt, tt::Type{<:Tuple}, depth::Int)
    codes = try
        _code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world, cfg)
    catch e
        _auto_debug_emit(
            cfg,
            Dict(
                "event" => "auto_debug_ir_error",
                "time_ns" => time_ns(),
                "tt" => string(tt),
                "depth" => depth,
                "error" => sprint(showerror, e),
            ),
        )
        return nothing
    end
    ir_entries = Any[]
    for entry in codes
        ir = entry.first
        ty = entry.second
        ir isa CC.IRCode || continue
        push!(
            ir_entries,
            Dict("ir" => _auto_debug_ir_string(ir), "inferred_type" => string(ty)),
        )
    end
    _auto_debug_emit(
        cfg,
        Dict(
            "event" => "auto_debug_ir",
            "time_ns" => time_ns(),
            "tt" => string(tt),
            "depth" => depth,
            "optimize_until" => cfg.optimize_until,
            "entries" => ir_entries,
        ),
    )
    return nothing
end

function _auto_debug_emit_check!(
    tt::Type{<:Tuple},
    cfg::Config,
    world::UInt,
    summary_snapshot,
    ok::Bool,
    violations::Vector{BorrowViolation},
    err,
    bt,
)
    t_ns = time_ns()
    err_s = if err === nothing
        nothing
    else
        try
            sprint(showerror, err, bt)
        catch
            try
                sprint(showerror, err)
            catch
                string(err)
            end
        end
    end
    _auto_debug_emit(
        cfg,
        Dict(
            "event" => "auto_debug_check",
            "time_ns" => t_ns,
            "time_s" => t_ns * 1e-9,
            "path" => _auto_debug_path(),
            "julia_version" => VERSION,
            "world" => world,
            "tt" => string(tt),
            "cfg" => _auto_debug_cfg_dict(cfg),
            "ok" => ok,
            "error" => err_s,
        ),
    )

    if !ok && err_s !== nothing
        _auto_debug_emit(
            cfg,
            Dict(
                "event" => "auto_debug_error",
                "time_ns" => time_ns(),
                "tt" => string(tt),
                "error" => err_s,
            ),
        )
    end

    if !isempty(violations)
        _auto_debug_emit(
            cfg,
            Dict(
                "event" => "auto_debug_violations",
                "time_ns" => time_ns(),
                "tt" => string(tt),
                "violations" => map(_auto_debug_borrow_violation_dict, violations),
            ),
        )
    end

    (new_mi, new_tt) = _auto_debug_collect_new_summaries(world, cfg, summary_snapshot)
    _auto_debug_emit(
        cfg,
        Dict(
            "event" => "auto_debug_summaries",
            "time_ns" => time_ns(),
            "tt" => string(tt),
            "new_mi_summaries" => new_mi,
            "new_tt_summaries" => new_tt,
        ),
    )

    try
        _auto_debug_emit_ir_for_tt(cfg, world, tt, 0)
    catch
    end
    if cfg.debug_callee_depth > 0
        tt0 = summary_snapshot === nothing ? Set{Any}() : summary_snapshot[2]
        Base.@lock SUMMARY_STATE begin
            for (k, entry) in SUMMARY_STATE[].tt_summary_cache
                (k[2] == world && k[3] == cfg) || continue
                (k in tt0) && continue
                entry.depth <= cfg.debug_callee_depth || continue
                k1 = k[1]
                k1 isa Type{<:Tuple} || continue
                try
                    _auto_debug_emit_ir_for_tt(cfg, world, k1, entry.depth)
                catch
                end
            end
        end
    end

    return nothing
end
