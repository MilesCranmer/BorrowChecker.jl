struct SummaryCacheEntry
    summary::EffectSummary
    depth::Int
    over_budget::Bool
end

const SUMMARY_CACHE_KEY = Tuple{Any,UInt,Config}

const SUMMARY_STATE = Lockable((
    summary_cache=Dict{SUMMARY_CACHE_KEY,SummaryCacheEntry}(),
    tt_summary_cache=Dict{SUMMARY_CACHE_KEY,SummaryCacheEntry}(),
    summary_inprogress=Set{SUMMARY_CACHE_KEY}(),
    tt_summary_inprogress=Set{SUMMARY_CACHE_KEY}(),
))

const TLS_REFLECTION_CTX_KEY = :BorrowCheckerAuto__reflection_ctx

function _reflection_ctx()
    return get(Base.task_local_storage(), TLS_REFLECTION_CTX_KEY, nothing)
end

function _reflection_world(default::UInt=Base.get_world_counter())
    ctx = _reflection_ctx()
    return (ctx === nothing) ? default : ctx.world
end

function _with_reflection_ctx(f::Function, world::UInt)
    @nospecialize f
    tls = Base.task_local_storage()
    old = get(tls, TLS_REFLECTION_CTX_KEY, nothing)
    tls[TLS_REFLECTION_CTX_KEY] = (; world=world, interp=BCInterp(; world))
    try
        return f()
    finally
        if old === nothing
            pop!(tls, TLS_REFLECTION_CTX_KEY, nothing)
        else
            (tls[TLS_REFLECTION_CTX_KEY] = old)
        end
    end
end

function _code_ircode_by_type(tt::Type; optimize_until, world::UInt)
    interp = BCInterp(; world)
    matches = Base._methods_by_ftype(tt, -1, world)
    if isnothing(matches)
        error("No method found matching signature $tt in world $world")
    end

    # For concrete call signatures, `Base._methods_by_ftype` can still return multiple
    # applicable methods (e.g. both `f(::Any, ::Any)` and `f(::Any, ::Symbol)` for
    # `Tuple{typeof(f), T, Symbol}`). At runtime dispatch will pick the most-specific
    # method; unioning effects across all matches can introduce large, spurious
    # conservatism (common for `getproperty`, keyword wrappers, etc.).
    #
    # When the tuple type is concrete enough, keep only the most-specific match.
    matches = let tt_u = Base.unwrap_unionall(tt)
        if tt_u isa DataType
            params = tt_u.parameters
            concrete = true
            for p in params
                if p === Any || p isa Union || p isa Core.TypeVar || p isa Core.TypeofVararg
                    concrete = false
                    break
                end
            end
            concrete ? (matches[1:1]) : matches
        else
            matches
        end
    end

    optimize_until = _normalize_optimize_until_for_ir(optimize_until)
    asts = Pair{Any,Any}[]
    for match in matches
        match = match::Core.MethodMatch
        (code, ty) = CC.typeinf_ircode(interp, match, optimize_until)
        if code === nothing
            push!(asts, match.method => Any)
        else
            push!(asts, code => ty)
        end
    end
    return asts
end

function _normalize_optimize_until_for_ir(optimize_until)
    optimize_until isa String || return optimize_until
    isdefined(CC, :ALL_PASS_NAMES) || return optimize_until

    for nm in CC.ALL_PASS_NAMES
        s = String(nm)
        s == optimize_until && return s
    end

    @inline function _norm(s::AbstractString)
        return replace(lowercase(String(s)), r"[^a-z0-9]+" => "")
    end

    optn = _norm(optimize_until)
    for nm in CC.ALL_PASS_NAMES
        s = String(nm)
        endswith(_norm(s), optn) && return s
    end

    return optimize_until
end

mutable struct BudgetTracker
    hit::Bool
end

function _mark_budget_hit!(@nospecialize(budget_state))
    budget_state === nothing && return nothing
    budget_state.hit = true
    return nothing
end

function _choose_summary_entry(old::SummaryCacheEntry, new::SummaryCacheEntry)
    # NOTE: `_choose_summary_entry` is only called when there is an existing cache entry
    # and we're recomputing because the existing entry was over budget at a deeper
    # summary depth. Therefore `old.over_budget` is expected to be true here.
    @assert old.over_budget
    if !new.over_budget
        return new
    end
    return (new.depth < old.depth) ? new : old
end

function _summary_state_get_tt(key::SUMMARY_CACHE_KEY)
    Base.@lock SUMMARY_STATE begin
        return get(SUMMARY_STATE[].tt_summary_cache, key, nothing)
    end
end

function _summary_state_get_mi(key::SUMMARY_CACHE_KEY)
    Base.@lock SUMMARY_STATE begin
        return get(SUMMARY_STATE[].summary_cache, key, nothing)
    end
end

function _summary_state_set_tt!(key::SUMMARY_CACHE_KEY, new_entry::SummaryCacheEntry)
    Base.@lock SUMMARY_STATE begin
        cache = SUMMARY_STATE[].tt_summary_cache
        old = get(cache, key, nothing)
        cache[key] = (old === nothing) ? new_entry : _choose_summary_entry(old, new_entry)
    end
    return nothing
end

function _summary_state_set_mi!(key::SUMMARY_CACHE_KEY, new_entry::SummaryCacheEntry)
    Base.@lock SUMMARY_STATE begin
        cache = SUMMARY_STATE[].summary_cache
        old = get(cache, key, nothing)
        cache[key] = (old === nothing) ? new_entry : _choose_summary_entry(old, new_entry)
    end
    return nothing
end

function _summary_state_tt_inprogress_enter!(key::SUMMARY_CACHE_KEY)::Bool
    reentered = false
    Base.@lock SUMMARY_STATE begin
        inprog = SUMMARY_STATE[].tt_summary_inprogress
        reentered = (key in inprog)
        reentered || push!(inprog, key)
    end
    return reentered
end

function _summary_state_tt_inprogress_exit!(key::SUMMARY_CACHE_KEY)
    Base.@lock SUMMARY_STATE begin
        delete!(SUMMARY_STATE[].tt_summary_inprogress, key)
    end
    return nothing
end

function _summary_state_mi_inprogress_enter!(key::SUMMARY_CACHE_KEY)::Bool
    reentered = false
    Base.@lock SUMMARY_STATE begin
        inprog = SUMMARY_STATE[].summary_inprogress
        reentered = (key in inprog)
        reentered || push!(inprog, key)
    end
    return reentered
end

function _summary_state_mi_inprogress_exit!(key::SUMMARY_CACHE_KEY)
    Base.@lock SUMMARY_STATE begin
        delete!(SUMMARY_STATE[].summary_inprogress, key)
    end
    return nothing
end

function _summary_cached(
    compute::FCompute,
    key,
    cfg::Config;
    depth::Int,
    budget_state=nothing,
    get_cached::FGet,
    set_cached::FSet,
    inprogress_enter::FEnter,
    inprogress_exit::FExit,
) where {FCompute<:Function,FGet<:Function,FSet<:Function,FEnter<:Function,FExit<:Function}
    cached = get_cached(key)
    if cached !== nothing
        if !cached.over_budget || depth >= cached.depth
            cached.over_budget && _mark_budget_hit!(budget_state)
            return cached.summary
        end
    end

    budget_state !== nothing && budget_state.hit && return nothing

    if inprogress_enter(key)
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
        inprogress_exit(key)
    end

    if summ !== nothing
        set_cached(key, SummaryCacheEntry(summ, depth, local_budget.hit))
    end

    cached2 = get_cached(key)
    cached2 !== nothing && cached2.over_budget && _mark_budget_hit!(budget_state)
    return cached2 === nothing ? summ : cached2.summary
end

function _summary_cached_tt(
    compute::Function, key, cfg::Config; depth::Int, budget_state=nothing, allow_core::Bool
)
    return _summary_cached(
        compute,
        key,
        cfg;
        depth=depth,
        budget_state=budget_state,
        get_cached=_summary_state_get_tt,
        set_cached=_summary_state_set_tt!,
        inprogress_enter=_summary_state_tt_inprogress_enter!,
        inprogress_exit=_summary_state_tt_inprogress_exit!,
    )
end

function _summary_cached_mi(
    compute::Function, key, cfg::Config; depth::Int, budget_state=nothing
)
    return _summary_cached(
        compute,
        key,
        cfg;
        depth=depth,
        budget_state=budget_state,
        get_cached=_summary_state_get_mi,
        set_cached=_summary_state_set_mi!,
        inprogress_enter=_summary_state_mi_inprogress_enter!,
        inprogress_exit=_summary_state_mi_inprogress_exit!,
    )
end

function _summarize_entries(codes, cfg::Config; depth::Int, budget_state=nothing)
    writes = BitSet()
    consumes = BitSet()
    ret_aliases = BitSet()
    got = false

    for entry in codes
        ir = entry.first
        ir isa CC.IRCode || continue
        got = true
        s = _summarize_ir_effects(ir, cfg; depth=depth, budget_state=budget_state)
        union!(writes, s.writes)
        union!(consumes, s.consumes)
        union!(ret_aliases, s.ret_aliases)
    end

    got || return nothing
    return EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
end

function _summary_for_tt(
    tt::Type{<:Tuple}, cfg::Config; depth::Int, budget_state=nothing, allow_core::Bool=false
)
    world = _reflection_world()
    key = (tt, UInt(world), cfg)

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
                if m === Auto || (!allow_core && m === Core)
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
        return _summarize_entries(codes, cfg; depth=depth, budget_state=local_budget)
    end
end

function _summary_for_mi(mi, cfg::Config; depth::Int, budget_state=nothing)
    try
        if mi isa Core.MethodInstance
            m = mi.def
            if (m isa Method) && (m.module === Core || m.module === Auto)
                return nothing
            end
        end
    catch
        return nothing
    end

    world = _reflection_world()
    key = (mi, UInt(world), cfg)

    return _summary_cached_mi(
        key, cfg; depth=depth, budget_state=budget_state
    ) do local_budget
        tt = mi.specTypes
        codes = _code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        return _summarize_entries(codes, cfg; depth=depth, budget_state=local_budget)
    end
end

function _widenargtype_or_any(@nospecialize(x), ir::CC.IRCode)
    try
        t = CC.widenconst(_safe_argextype(x, ir))
        return (t isa Type) ? t : Any
    catch
        return Any
    end
end

function _is_box_contents_setfield!(
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

    # Treat most `Type(...)` calls (constructors/conversions) as pure with respect to
    # ownership: constructing a new object that (may) hold references to inputs should
    # create aliases, not "move"/consume the inputs.
    #
    # Exception: callable objects (subtypes of `Function`) model captured environments
    # (closures/functors) that can escape and outlive the current scope, so keep the
    # normal conservative behavior for those.
    if head === :call && f isa Type
        # If a `Type(...)` call has explicit known effects (e.g. `Task(f)`), honor them.
        if _known_effects_get(f) === nothing
            is_functor = (f <: Function)
            is_functor || return EffectSummary()
        end
    end

    # `_apply_iterate` is Core plumbing used for splatting/varargs and some wrappers.
    # Treat it as a transparent call wrapper: infer effects for the callee (`raw_args[3]`)
    # on the expanded argument list, then map those effects back to the original
    # `_apply_iterate` argument positions. This avoids spurious "consume" results for
    # Base wrappers like `setindex!` that route through `_apply_iterate`.
    if f === Core._apply_iterate && length(raw_args) >= 3
        # Inner callee
        inner_f = try
            CC.singleton_type(_safe_argextype(raw_args[3], ir))
        catch
            nothing
        end
        if inner_f === nothing && raw_args[3] isa GlobalRef
            inner_f = try
                getfield(raw_args[3].mod, raw_args[3].name)
            catch
                nothing
            end
        end
        if inner_f !== nothing
            expanded_types = Any[typeof(inner_f)]
            posmap = Int[3]

            # Expand tuple arguments when possible; otherwise treat as a splat-container
            # described by its tuple type (when statically known).
            for j in 4:length(raw_args)
                argj = raw_args[j]
                elems = _maybe_tuple_elements(argj, ir)
                if elems !== nothing
                    for e in elems
                        push!(expanded_types, _widenargtype_or_any(e, ir))
                        push!(posmap, j)
                    end
                    continue
                end

                # In `_apply_iterate`, arguments after the callee are typically splat-containers.
                # If we know this container is a concrete Tuple type, expand its element types
                # so the inferred callee TT matches the post-splat argument list.
                Tj = _widenargtype_or_any(argj, ir)
                if Tj === Tuple{}
                    continue
                end
                dt = Base.unwrap_unionall(Tj)
                if dt isa DataType && dt.name === Tuple.name
                    params = dt.parameters
                    has_vararg = any(p -> p isa Core.TypeofVararg, params)
                    if !has_vararg
                        for te in params
                            te2 = Base.unwrap_unionall(te)
                            push!(expanded_types, (te2 isa Type) ? te2 : Any)
                            push!(posmap, j)
                        end
                        continue
                    end
                end

                # Unknown or non-tuple splat-container: treat as a single argument.
                push!(expanded_types, Tj)
                push!(posmap, j)
            end

            tt = Core.apply_type(Tuple, expanded_types...)
            s_inner = _known_effects_get(inner_f)
            if s_inner === nothing && tt !== nothing && depth < cfg.max_summary_depth
                s_inner = _summary_for_tt(
                    tt, cfg; depth=depth + 1, budget_state=budget_state
                )
            end

            if s_inner !== nothing
                writes = BitSet()
                consumes = BitSet()
                ret_aliases = BitSet()
                for p in s_inner.writes
                    (1 <= p <= length(posmap)) || continue
                    push!(writes, posmap[p])
                end
                for p in s_inner.consumes
                    (1 <= p <= length(posmap)) || continue
                    push!(consumes, posmap[p])
                end
                for p in s_inner.ret_aliases
                    (1 <= p <= length(posmap)) || continue
                    push!(ret_aliases, posmap[p])
                end
                return EffectSummary(;
                    writes=writes, consumes=consumes, ret_aliases=ret_aliases
                )
            end
        end
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

    if f === Core.kwcall
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

    if head === :invoke && (mi !== nothing)
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

    if head === :call && f === nothing
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

    if head === :call && f !== nothing
        tt = _call_tt_from_raw_args(raw_args, ir, f)
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

    consumes = Int[]
    # `raw_args[1]` is the function value. Calling a function does not (by itself)
    # consume/move the function object, so treat only user arguments as candidates.
    for p in 2:length(raw_args)
        v = raw_args[p]
        h = _handle_index(v, nargs, track_arg, track_ssa)
        h == 0 && continue
        Tv = _widenargtype_or_any(v, ir)
        is_owned_type(Tv) || continue
        push!(consumes, p)
    end
    return EffectSummary(; consumes=consumes)
end

function _push_arg_aliases!(dest::BitSet, uf::UnionFind, root::Int, nargs::Int, track_arg)
    for a in 1:nargs
        track_arg[a] || continue
        if _uf_find(uf, a) == root
            push!(dest, a)
        end
    end
    return nothing
end

function _push_arg_aliases_for_handle!(
    dest::BitSet, uf::UnionFind, hv::Int, nargs::Int, track_arg
)
    hv == 0 && return nothing
    root = _uf_find(uf, hv)
    return _push_arg_aliases!(dest, uf, root, nargs, track_arg)
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
        if stmt isa Expr && stmt.head === :foreigncall
            name_sym, ccall_args, _gc_roots, _nccallargs = _foreigncall_parts(stmt)
            eff =
                (name_sym === nothing) ? nothing : _known_foreigncall_effects_get(name_sym)

            if eff === nothing
                # Unknown foreigncall: treat as write to the C arguments only (ignore GC roots).
                for v in ccall_args
                    hs = _backward_used_handles(v, ir, nargs, track_arg, track_ssa)
                    for hv in hs
                        _push_arg_aliases!(writes, uf, _uf_find(uf, hv), nargs, track_arg)
                    end
                end
                continue
            end

            for grp in eff.write_groups
                hs = _foreigncall_group_used_handles(
                    ccall_args, grp, ir, nargs, track_arg, track_ssa
                )
                for hv in hs
                    _push_arg_aliases!(writes, uf, _uf_find(uf, hv), nargs, track_arg)
                end
            end

            for grp in eff.consume_groups
                hs = _foreigncall_group_used_handles(
                    ccall_args, grp, ir, nargs, track_arg, track_ssa
                )
                for hv in hs
                    _push_arg_aliases!(consumes, uf, _uf_find(uf, hv), nargs, track_arg)
                end
            end

            continue
        end

        head, _mi, raw_args = _call_parts(stmt)
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
                    _push_arg_aliases_for_handle!(writes, uf, hv, nargs, track_arg)
                end
                continue
            end

            v = raw_args[p]
            hv = _handle_index(v, nargs, track_arg, track_ssa)
            _push_arg_aliases_for_handle!(writes, uf, hv, nargs, track_arg)
        end
        for p in eff.consumes
            if kw_vals !== nothing && p == 2
                for vkw in kw_vals
                    hv = _handle_index(vkw, nargs, track_arg, track_ssa)
                    _push_arg_aliases_for_handle!(consumes, uf, hv, nargs, track_arg)
                end
                continue
            end

            v = raw_args[p]
            hv = _handle_index(v, nargs, track_arg, track_ssa)
            _push_arg_aliases_for_handle!(consumes, uf, hv, nargs, track_arg)
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
