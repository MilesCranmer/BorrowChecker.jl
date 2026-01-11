struct SummaryCacheEntry
    summary::EffectSummary
    depth::Int
    over_budget::Bool
end

Base.@kwdef struct SummaryState
    summary_cache::IdDict{Any,SummaryCacheEntry} = IdDict{Any,SummaryCacheEntry}()
    tt_summary_cache::Dict{Tuple{Any,UInt},SummaryCacheEntry} = Dict{
        Tuple{Any,UInt},SummaryCacheEntry
    }()
    summary_inprogress::Base.IdSet{Any} = Base.IdSet{Any}()
    tt_summary_inprogress::Set{Tuple{Any,UInt}} = Set{Tuple{Any,UInt}}()
end

const _summary_state = Lockable(SummaryState())

const _TLS_REFLECTION_CTX_KEY = :BorrowCheckerExperimental__reflection_ctx

@inline function _reflection_ctx()
    return get(Base.task_local_storage(), _TLS_REFLECTION_CTX_KEY, nothing)
end

@inline function _reflection_world(default::UInt=Base.get_world_counter())
    ctx = _reflection_ctx()
    return (ctx === nothing) ? default : ctx.world
end

@inline function _reflection_interp()
    ctx = _reflection_ctx()
    return (ctx === nothing) ? nothing : ctx.interp
end

function _with_reflection_ctx(f::Function, world::UInt)
    tls = Base.task_local_storage()
    old = get(tls, _TLS_REFLECTION_CTX_KEY, nothing)
    tls[_TLS_REFLECTION_CTX_KEY] = (; world=world, interp=CC.NativeInterpreter(world))
    try
        return f()
    finally
        if old === nothing
            pop!(tls, _TLS_REFLECTION_CTX_KEY, nothing)
        else
            (tls[_TLS_REFLECTION_CTX_KEY] = old)
        end
    end
end

function _code_ircode_by_type(tt::Type; optimize_until, world::UInt)
    interp = _reflection_interp()
    if interp === nothing
        return Base.code_ircode_by_type(tt; optimize_until=optimize_until, world=world)
    end
    return Base.code_ircode_by_type(
        tt; optimize_until=optimize_until, world=world, interp=interp
    )
end

mutable struct BudgetTracker
    hit::Bool
end

@inline function _mark_budget_hit!(@nospecialize(budget_state))
    budget_state === nothing && return nothing
    budget_state.hit = true
    return nothing
end

@inline function _choose_summary_entry(old::SummaryCacheEntry, new::SummaryCacheEntry)
    if !old.over_budget
        return old
    end
    if !new.over_budget
        return new
    end
    return (new.depth < old.depth) ? new : old
end

function _summary_cached_tt(
    compute::Function, key, cfg::Config; depth::Int, budget_state=nothing, allow_core::Bool
)
    cached = nothing
    Base.@lock _summary_state begin
        cached = get(_summary_state[].tt_summary_cache, key, nothing)
    end
    if cached !== nothing
        if !cached.over_budget || depth >= cached.depth
            cached.over_budget && _mark_budget_hit!(budget_state)
            return cached.summary
        end
    end

    if budget_state !== nothing
        budget_state.hit && return nothing
    end

    reentered = false
    Base.@lock _summary_state begin
        reentered = (key in _summary_state[].tt_summary_inprogress)
        reentered || push!(_summary_state[].tt_summary_inprogress, key)
    end
    if reentered
        _mark_budget_hit!(budget_state)
        return nothing
    end

    summ = nothing
    local_budget = BudgetTracker(false)
    try
        summ = compute(local_budget)
    catch
        summ = nothing
    finally
        Base.@lock _summary_state begin
            delete!(_summary_state[].tt_summary_inprogress, key)
        end
    end

    if summ !== nothing
        new_entry = SummaryCacheEntry(summ, depth, local_budget.hit)
        Base.@lock _summary_state begin
            old = get(_summary_state[].tt_summary_cache, key, nothing)
            _summary_state[].tt_summary_cache[key] =
                (old === nothing) ? new_entry : _choose_summary_entry(old, new_entry)
        end
    end

    cached2 = nothing
    Base.@lock _summary_state begin
        cached2 = get(_summary_state[].tt_summary_cache, key, nothing)
    end
    cached2 !== nothing && cached2.over_budget && _mark_budget_hit!(budget_state)
    return cached2 === nothing ? summ : cached2.summary
end

function _summary_cached_mi(
    compute::Function, key, cfg::Config; depth::Int, budget_state=nothing
)
    cached = nothing
    Base.@lock _summary_state begin
        cached = get(_summary_state[].summary_cache, key, nothing)
    end
    if cached !== nothing
        if !cached.over_budget || depth >= cached.depth
            cached.over_budget && _mark_budget_hit!(budget_state)
            return cached.summary
        end
    end

    if budget_state !== nothing
        budget_state.hit && return nothing
    end

    reentered = false
    Base.@lock _summary_state begin
        reentered = (key in _summary_state[].summary_inprogress)
        reentered || push!(_summary_state[].summary_inprogress, key)
    end
    if reentered
        _mark_budget_hit!(budget_state)
        return nothing
    end

    summ = nothing
    local_budget = BudgetTracker(false)
    try
        summ = compute(local_budget)
    catch
        summ = nothing
    finally
        Base.@lock _summary_state begin
            delete!(_summary_state[].summary_inprogress, key)
        end
    end

    if summ !== nothing
        new_entry = SummaryCacheEntry(summ, depth, local_budget.hit)
        Base.@lock _summary_state begin
            old = get(_summary_state[].summary_cache, key, nothing)
            _summary_state[].summary_cache[key] =
                (old === nothing) ? new_entry : _choose_summary_entry(old, new_entry)
        end
    end

    cached2 = nothing
    Base.@lock _summary_state begin
        cached2 = get(_summary_state[].summary_cache, key, nothing)
    end
    cached2 !== nothing && cached2.over_budget && _mark_budget_hit!(budget_state)
    return cached2 === nothing ? summ : cached2.summary
end

function _summary_for_tt(
    tt::Type{<:Tuple}, cfg::Config; depth::Int, budget_state=nothing, allow_core::Bool=false
)
    world = _reflection_world()
    key = (tt, UInt(world))

    try
        tt_u = Base.unwrap_unionall(tt)
        if tt_u isa DataType && !isempty(tt_u.parameters)
            fT = tt_u.parameters[1]
            dt = Base.unwrap_unionall(fT)
            if dt isa DataType
                m = dt.name.module
                if dt.name === Base.unwrap_unionall(Type).name && !isempty(dt.parameters)
                    targ = Base.unwrap_unionall(dt.parameters[1])
                    if targ isa DataType
                        m = targ.name.module
                    end
                end
                if m === Experimental || (!allow_core && m === Core)
                    return nothing
                end
            end
        end
    catch
    end

    return _summary_cached_tt(
        key, cfg; depth=depth, budget_state=budget_state, allow_core=allow_core
    ) do local_budget
        codes = _code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        writes = BitSet()
        consumes = BitSet()
        ret_aliases = BitSet()
        got = false
        for entry in codes
            ir = entry.first
            ir isa CC.IRCode || continue
            got = true
            s = _summarize_ir_effects(ir, cfg; depth=depth, budget_state=local_budget)
            union!(writes, s.writes)
            union!(consumes, s.consumes)
            union!(ret_aliases, s.ret_aliases)
        end
        got || return nothing
        return EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
    end
end

function _summary_for_mi(mi, cfg::Config; depth::Int, budget_state=nothing)
    try
        if mi isa Core.MethodInstance
            m = mi.def
            if (m isa Method) && (m.module === Core || m.module === Experimental)
                return nothing
            end
        end
    catch
        return nothing
    end

    return _summary_cached_mi(
        mi, cfg; depth=depth, budget_state=budget_state
    ) do local_budget
        tt = mi.specTypes
        world = _reflection_world()
        codes = _code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        writes = BitSet()
        consumes = BitSet()
        ret_aliases = BitSet()
        got = false
        for entry in codes
            ir = entry.first
            ir isa CC.IRCode || continue
            got = true
            s = _summarize_ir_effects(ir, cfg; depth=depth, budget_state=local_budget)
            union!(writes, s.writes)
            union!(consumes, s.consumes)
            union!(ret_aliases, s.ret_aliases)
        end
        got || return nothing
        return EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
    end
end

@inline function _widenargtype_or_any(@nospecialize(x), ir::CC.IRCode)
    try
        t = CC.widenconst(CC.argextype(x, ir))
        return (t isa Type) ? t : Any
    catch
        return Any
    end
end

@inline function _is_box_contents_setfield!(
    @nospecialize(f), raw_args::AbstractVector, ir::CC.IRCode
)::Bool
    f === Core.setfield! || return false
    length(raw_args) >= 4 || return false
    fld = raw_args[3]
    fldsym = fld isa QuoteNode ? fld.value : fld
    fldsym === :contents || return false

    obj = raw_args[2]
    Tobj = _widenargtype_or_any(obj, ir)
    if isdefined(Core, :Box)
        try
            return Tobj <: Core.Box
        catch
            return false
        end
    end
    return false
end

function _filter_consumes_for_call(
    @nospecialize(f),
    raw_args::AbstractVector,
    eff::EffectSummary,
    ir::CC.IRCode,
    nargs::Int,
    track_arg,
    track_ssa,
)::EffectSummary
    isempty(eff.consumes) && return eff

    consumes = BitSet()
    for p in eff.consumes
        (1 <= p <= length(raw_args)) || continue

        # Captured-variable boxing uses `setfield!(box, :contents, val)` as an
        # implementation detail. Treat this as aliasing, not an ownership move.
        if p == 4 && _is_box_contents_setfield!(f, raw_args, ir)
            continue
        end

        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue

        Tv = _widenargtype_or_any(v, ir)
        is_owned_type(Tv) || continue

        push!(consumes, p)
    end

    consumes == eff.consumes && return eff
    return EffectSummary(;
        writes=eff.writes, consumes=consumes, ret_aliases=eff.ret_aliases
    )
end

function _effects_for_call(
    stmt,
    ir::CC.IRCode,
    cfg::Config,
    track_arg,
    track_ssa,
    nargs::Int;
    idx::Int=0,
    depth::Int=0,
    budget_state=nothing,
)::EffectSummary
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return EffectSummary()
    f = _resolve_callee(stmt, ir)

    if idx != 0
        Tret = try
            inst = ir[Core.SSAValue(idx)]
            CC.widenconst(_inst_get(inst, :type, Any))
        catch
            Any
        end
        if Tret === Union{}
            return EffectSummary()
        end
    end

    if f === __bc_bind__
        return EffectSummary()
    end

    if f !== nothing
        s = _known_effects_get(f)
        s === nothing || return _filter_consumes_for_call(
            f, raw_args, s, ir, nargs, track_arg, track_ssa
        )
    end

    if f !== nothing && _is_namedtuple_ctor(f)
        return EffectSummary()
    end

    if f === Core.kwcall && cfg.analyze_invokes
        tt_kw = _kwcall_tt_from_raw_args(raw_args, ir)
        if tt_kw !== nothing
            if depth < cfg.max_summary_depth
                s = _summary_for_tt(
                    tt_kw, cfg; depth=depth + 1, budget_state=budget_state, allow_core=true
                )
                if s !== nothing
                    return _filter_consumes_for_call(
                        f, raw_args, s, ir, nargs, track_arg, track_ssa
                    )
                end
            else
                _mark_budget_hit!(budget_state)
            end
        end
    end

    if head === :invoke && cfg.analyze_invokes && (mi !== nothing)
        if depth < cfg.max_summary_depth
            s = _summary_for_mi(mi, cfg; depth=depth + 1, budget_state=budget_state)
            if s !== nothing
                return _filter_consumes_for_call(
                    f, raw_args, s, ir, nargs, track_arg, track_ssa
                )
            end
        else
            _mark_budget_hit!(budget_state)
        end
    end

    if head === :call && cfg.analyze_invokes && f === nothing
        fexpr = raw_args[1]
        if fexpr isa Core.SSAValue
            tt = _call_tt_from_raw_args(raw_args, ir)
            if tt !== nothing
                if depth < cfg.max_summary_depth
                    s = _summary_for_tt(tt, cfg; depth=depth + 1, budget_state=budget_state)
                    if s !== nothing
                        return _filter_consumes_for_call(
                            f, raw_args, s, ir, nargs, track_arg, track_ssa
                        )
                    end
                else
                    _mark_budget_hit!(budget_state)
                end
            end
        end
    end

    if head === :call && cfg.analyze_invokes && f !== nothing
        tt = _call_tt_from_raw_args(raw_args, ir)
        if tt !== nothing
            if depth < cfg.max_summary_depth
                s = _summary_for_tt(tt, cfg; depth=depth + 1, budget_state=budget_state)
                if s !== nothing
                    return _filter_consumes_for_call(
                        f, raw_args, s, ir, nargs, track_arg, track_ssa
                    )
                end
            else
                _mark_budget_hit!(budget_state)
            end
        end
    end

    if cfg.unknown_call_policy === :consume
        consumes = Int[]
        for p in 1:length(raw_args)
            v = raw_args[p]
            h = _handle_index(v, nargs, track_arg, track_ssa)
            h == 0 && continue
            Tv = _widenargtype_or_any(v, ir)
            is_owned_type(Tv) || continue
            push!(consumes, p)
        end
        return EffectSummary(; consumes=consumes)
    else
        return EffectSummary()
    end
end

function _summarize_ir_effects(
    ir::CC.IRCode, cfg::Config; depth::Int, budget_state=nothing
)::EffectSummary
    nargs = length(ir.argtypes)
    nstmts = length(ir.stmts)
    track_arg, track_ssa = compute_tracking_masks(ir)

    uf = UnionFind(nargs + nstmts)
    _build_alias_classes!(
        uf, ir, cfg, track_arg, track_ssa, nargs; depth=depth, budget_state=budget_state
    )

    writes = BitSet()
    consumes = BitSet()
    ret_aliases = BitSet()

    for i in 1:nstmts
        stmt = ir[Core.SSAValue(i)][:stmt]
        head, _mi, raw_args = _call_parts(stmt)
        if stmt isa Expr && stmt.head === :foreigncall
            uses = _used_handles(stmt, ir, nargs, track_arg, track_ssa)
            for hv in uses
                rv = _uf_find(uf, hv)
                for a in 1:nargs
                    track_arg[a] || continue
                    if _uf_find(uf, a) == rv
                        push!(writes, a)
                    end
                end
            end
            continue
        end

        raw_args === nothing && continue

        eff = _effects_for_call(
            stmt,
            ir,
            cfg,
            track_arg,
            track_ssa,
            nargs;
            idx=i,
            depth=depth,
            budget_state=budget_state,
        )

        kw_vals = _kwcall_value_exprs(stmt, ir)
        (kw_vals === nothing || isempty(kw_vals)) && (kw_vals = nothing)

        for p in eff.writes
            if kw_vals !== nothing && p == 2
                for vkw in kw_vals
                    hv = _handle_index(vkw, nargs, track_arg, track_ssa)
                    hv == 0 && continue
                    rv = _uf_find(uf, hv)
                    for a in 1:nargs
                        track_arg[a] || continue
                        if _uf_find(uf, a) == rv
                            push!(writes, a)
                        end
                    end
                end
                continue
            end

            v = raw_args[p]
            hv = _handle_index(v, nargs, track_arg, track_ssa)
            hv == 0 && continue
            rv = _uf_find(uf, hv)
            for a in 1:nargs
                track_arg[a] || continue
                if _uf_find(uf, a) == rv
                    push!(writes, a)
                end
            end
        end
        for p in eff.consumes
            if kw_vals !== nothing && p == 2
                for vkw in kw_vals
                    hv = _handle_index(vkw, nargs, track_arg, track_ssa)
                    hv == 0 && continue
                    rv = _uf_find(uf, hv)
                    for a in 1:nargs
                        track_arg[a] || continue
                        if _uf_find(uf, a) == rv
                            push!(consumes, a)
                        end
                    end
                end
                continue
            end

            v = raw_args[p]
            hv = _handle_index(v, nargs, track_arg, track_ssa)
            hv == 0 && continue
            rv = _uf_find(uf, hv)
            for a in 1:nargs
                track_arg[a] || continue
                if _uf_find(uf, a) == rv
                    push!(consumes, a)
                end
            end
        end
    end

    for i in 1:nstmts
        stmt = ir[Core.SSAValue(i)][:stmt]
        rv = if stmt isa Core.ReturnNode
            isdefined(stmt, :val) ? stmt.val : nothing
        elseif stmt isa Expr && stmt.head === :return && !isempty(stmt.args)
            stmt.args[1]
        else
            continue
        end
        hrv = _handle_index(rv, nargs, track_arg, track_ssa)
        hrv == 0 && continue
        rroot = _uf_find(uf, hrv)
        for a in 1:nargs
            track_arg[a] || continue
            if _uf_find(uf, a) == rroot
                push!(ret_aliases, a)
            end
        end
    end

    return EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
end
