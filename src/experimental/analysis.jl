function _call_parts(stmt)
    if stmt isa Expr && stmt.head === :invoke
        # Expr(:invoke, mi, f, arg1, arg2, ...)
        mi = stmt.args[1]
        raw_args = stmt.args[2:end]
        return (:invoke, mi, raw_args)
    elseif stmt isa Expr && stmt.head === :call
        raw_args = stmt.args
        return (:call, nothing, raw_args)
    else
        return (nothing, nothing, nothing)
    end
end

function _resolve_callee(@nospecialize(stmt), ir::CC.IRCode)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing
    fexpr = raw_args[1]

    # Calls through a variable callee (function arguments) are treated as unknown,
    # even if inference constant-propagates the callee value for this specialization.
    #
    # This makes `unknown_call_policy` robust to constant-prop in higher-order code:
    # `f(x)` where `f` is an argument stays "unknown" for borrow checking.
    if fexpr isa Core.Argument
        return nothing
    end

    try
        ft = CC.argextype(fexpr, ir)
        return CC.singleton_type(ft)
    catch
        return nothing
    end
end

function _callee_name_str(@nospecialize(f))
    try
        return String(Base.nameof(f))
    catch
        return ""
    end
end

function _is_functor_instance(@nospecialize(f))
    try
        f isa DataType && return false
        tf = typeof(f)
        tf isa DataType || return false
        return fieldcount(tf) > 0
    catch
        return false
    end
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

    # Our own internal helpers are treated as pure.
    if f === __bc_bind__
        return EffectSummary()
    end

    # Table overrides.
    if f !== nothing
        s = _known_effects_get(f)
        s === nothing || return s
    end

    # If we have a statically resolved method instance, we can optionally summarize it.
    if head === :invoke && cfg.analyze_invokes && (mi !== nothing)
        if depth < cfg.max_summary_depth
            s = _summary_for_mi(mi, cfg; depth=depth + 1, budget_state=budget_state)
            if s !== nothing
                return s
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
                        return s
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
                    return s
                end
            else
                _mark_budget_hit!(budget_state)
            end
        end
    end

    # Unknown call policy.
    if cfg.unknown_call_policy === :consume
        consumes = Int[]
        for p in 1:length(raw_args)
            h = _handle_index(raw_args[p], nargs, track_arg, track_ssa)
            h == 0 && continue
            push!(consumes, p)
        end
        return EffectSummary(; consumes=consumes)
    else
        return EffectSummary()
    end
end

function _call_tt_from_raw_args(raw_args, ir::CC.IRCode)
    types = Any[]
    for a in raw_args
        t = Any
        try
            t = CC.widenconst(CC.argextype(a, ir))
        catch
            t = Any
        end
        if t === Any && a isa Core.SSAValue
            t = _maybe_box_contents_type(a, ir)
        end
        (t isa Type) || (t = Any)
        push!(types, t)
    end
    isempty(types) && return nothing

    fT = types[1]
    if fT === Any || fT isa Union
        return nothing
    end
    dt = try
        Base.unwrap_unionall(fT)
    catch
        return nothing
    end
    dt isa DataType || return nothing
    if Base.isabstracttype(dt)
        if !(dt.name === Base.unwrap_unionall(Type).name && !isempty(dt.parameters))
            return nothing
        end
    end

    try
        return Tuple{types...}
    catch
        return nothing
    end
end

function _maybe_box_contents_type(x::Core.SSAValue, ir::CC.IRCode)
    x = _canonical_ref(x, ir)
    stmt = try
        ir[x][:stmt]
    catch
        return Any
    end
    stmt isa Expr && stmt.head === :call || return Any
    (stmt.args[1] === Core.getfield || stmt.args[1] == GlobalRef(Core, :getfield)) || return Any
    length(stmt.args) >= 3 || return Any
    fld = stmt.args[3]
    fldsym = fld isa QuoteNode ? fld.value : fld
    fldsym === :contents || return Any
    box = _canonical_ref(stmt.args[2], ir)

    for i in 1:length(ir.stmts)
        st = ir[Core.SSAValue(i)][:stmt]
        st isa Expr && st.head === :call || continue
        (st.args[1] === Core.setfield! || st.args[1] == GlobalRef(Core, :setfield!)) || continue
        length(st.args) >= 4 || continue
        f = st.args[3]
        fsym = f isa QuoteNode ? f.value : f
        fsym === :contents || continue
        box2 = _canonical_ref(st.args[2], ir)
        box2 == box || continue
        v = st.args[4]
        t = try
            CC.widenconst(CC.argextype(v, ir))
        catch
            Any
        end
        return (t isa Type) ? t : Any
    end

    return Any
end

function _summary_for_tt(tt::Type{<:Tuple}, cfg::Config; depth::Int, budget_state=nothing)
    world = Base.get_world_counter()
    key = (tt, UInt(world))
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
                if m === Core || m === Experimental
                    return nothing
                end
            end
        end
    catch
    end

    # Reentrancy guard: keyword-argument lowering and other compiler-generated machinery
    # can produce cyclic call graphs (including self-cycles) in the IR summarization pass.
    # If we re-enter summarization for the same `(tt, world)` while it's still being
    # computed, return `nothing` and let the caller fall back to `unknown_call_policy`.
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
        codes = Base.code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
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
        summ = EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
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

function _summary_for_mi(mi, cfg::Config; depth::Int, budget_state=nothing)
    # Avoid summarizing Base/Core in this MVP: it's huge and unstable across versions.
    try
        if mi isa Core.MethodInstance
            m = mi.def
            if (m isa Method) && (m.module === Core || m.module === Experimental)
                return nothing
            end
        end
    catch
        # if reflection fails, just skip
        return nothing
    end

    cached = nothing
    Base.@lock _summary_state begin
        cached = get(_summary_state[].summary_cache, mi, nothing)
    end
    if cached !== nothing
        if !cached.over_budget || depth >= cached.depth
            cached.over_budget && _mark_budget_hit!(budget_state)
            return cached.summary
        end
    end

    reentered = false
    Base.@lock _summary_state begin
        reentered = (mi in _summary_state[].summary_inprogress)
        reentered || push!(_summary_state[].summary_inprogress, mi)
    end
    if reentered
        _mark_budget_hit!(budget_state)
        return nothing
    end

    # Compute summary without holding the lock (avoid deadlocks during reflection/inference).
    summ = nothing
    local_budget = BudgetTracker(false)
    try
        tt = mi.specTypes
        world = Base.get_world_counter()
        codes = Base.code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
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
        summ = EffectSummary(; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
    catch
        summ = nothing
    finally
        Base.@lock _summary_state begin
            delete!(_summary_state[].summary_inprogress, mi)
        end
    end

    if summ !== nothing
        new_entry = SummaryCacheEntry(summ, depth, local_budget.hit)
        Base.@lock _summary_state begin
            old = get(_summary_state[].summary_cache, mi, nothing)
            _summary_state[].summary_cache[mi] =
                (old === nothing) ? new_entry : _choose_summary_entry(old, new_entry)
        end
    end

    cached2 = nothing
    Base.@lock _summary_state begin
        cached2 = get(_summary_state[].summary_cache, mi, nothing)
    end
    cached2 !== nothing && cached2.over_budget && _mark_budget_hit!(budget_state)
    return cached2 === nothing ? summ : cached2.summary
end

function _summarize_ir_effects(ir::CC.IRCode, cfg::Config; depth::Int, budget_state=nothing)::EffectSummary
    nargs = length(ir.argtypes)
    nstmts = length(ir.stmts)

    # Track which args/SSA are relevant.
    track_arg = Vector{Bool}(undef, nargs)
    for a in 1:nargs
        T = try
            CC.widenconst(ir.argtypes[a])
        catch
            Any
        end
        track_arg[a] = is_tracked_type(T)
    end
    track_ssa = Vector{Bool}(undef, nstmts)
    for i in 1:nstmts
        T = try
            inst = ir[Core.SSAValue(i)]
            CC.widenconst(_inst_get(inst, :type, Any))
        catch
            Any
        end
        track_ssa[i] = is_tracked_type(T)
    end

    # Alias union-find.
    uf = UnionFind(nargs + nstmts)
    _build_alias_classes!(uf, ir, cfg, track_arg, track_ssa, nargs; depth=depth, budget_state=budget_state)

    writes = BitSet()
    consumes = BitSet()
    ret_aliases = BitSet()

    for i in 1:nstmts
        stmt = ir[Core.SSAValue(i)][:stmt]
        head, _mi, raw_args = _call_parts(stmt)
        if stmt isa Expr && stmt.head === :foreigncall
            uses = _used_handles(stmt, nargs, track_arg, track_ssa)
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

        # Map actual argument positions back to formal arguments by alias class.
        for p in eff.writes
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

function _build_alias_classes!(
    uf::UnionFind,
    ir::CC.IRCode,
    cfg::Config,
    track_arg,
    track_ssa,
    nargs::Int;
    depth::Int=0,
    budget_state=nothing,
)
    box_contents = Dict{Int,Int}()

    nstmts = length(ir.stmts)
    for i in 1:nstmts
        out_h = track_ssa[i] ? _ssa_handle(nargs, i) : 0
        out_h == 0 && continue

        stmt = ir[Core.SSAValue(i)][:stmt]

        # PiNode(x, T) aliases x.
        if stmt isa Core.PiNode
            in_h = _handle_index(stmt.val, nargs, track_arg, track_ssa)
            _uf_union!(uf, out_h, in_h)
            continue
        end

        # Phi nodes alias any incoming value.
        if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
            vals = getfield(stmt, :values)
            for v in vals
                in_h = _handle_index(v, nargs, track_arg, track_ssa)
                _uf_union!(uf, out_h, in_h)
            end
            continue
        end

        # Plain SSA copies (e.g. `%19 = %11`) preserve aliasing.
        if stmt isa Core.SSAValue || stmt isa Core.Argument
            in_h = _handle_index(stmt, nargs, track_arg, track_ssa)
            _uf_union!(uf, out_h, in_h)
            continue
        end

        if stmt isa Expr && (stmt.head === :new || stmt.head === :splatnew)
            for j in 2:length(stmt.args)
                in_h = _handle_index(stmt.args[j], nargs, track_arg, track_ssa)
                _uf_union!(uf, out_h, in_h)
            end
            continue
        end

        # Calls: determine whether return aliases args.
        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            raw_args = (stmt.head === :invoke) ? stmt.args[2:end] : stmt.args
            f = _resolve_callee(stmt, ir)

            if f === Core.setfield! && length(raw_args) >= 4
                fld = raw_args[3]
                fldsym = fld isa QuoteNode ? fld.value : fld
                if fldsym === :contents
                    box = _canonical_ref(raw_args[2], ir)
                    key = if box isa Core.Argument
                        box.n
                    elseif box isa Core.SSAValue
                        _ssa_handle(nargs, box.id)
                    else
                        0
                    end
                    v = raw_args[4]
                    vh = _handle_index(v, nargs, track_arg, track_ssa)
                    (key != 0 && vh != 0) && (box_contents[key] = vh)
                end
            elseif f === Core.getfield && length(raw_args) >= 3
                fld = raw_args[3]
                fldsym = fld isa QuoteNode ? fld.value : fld
                if fldsym === :contents
                    box = _canonical_ref(raw_args[2], ir)
                    key = if box isa Core.Argument
                        box.n
                    elseif box isa Core.SSAValue
                        _ssa_handle(nargs, box.id)
                    else
                        0
                    end
                    if key != 0 && haskey(box_contents, key)
                        _uf_union!(uf, out_h, box_contents[key])
                    end
                end
            end

            # Fresh return overrides.
            if f !== nothing && _fresh_return_get(f)
                continue
            end

            alias_args = Int[]
            if f !== nothing && _ret_alias_has(f)
                style = _ret_alias_get(f)
                if style === :arg1
                    length(raw_args) >= 2 && push!(alias_args, 2)
                elseif style === :all
                    for p in 2:length(raw_args)
                        push!(alias_args, p)
                    end
                end
            elseif cfg.analyze_invokes
                s = nothing
                if depth < cfg.max_summary_depth
                    if stmt.head === :invoke
                        s = _summary_for_mi(stmt.args[1], cfg; depth=depth + 1, budget_state=budget_state)
                    else
                        tt = _call_tt_from_raw_args(raw_args, ir)
                        tt !== nothing && (s = _summary_for_tt(tt, cfg; depth=depth + 1, budget_state=budget_state))
                    end
                else
                    if stmt.head === :invoke
                        _mark_budget_hit!(budget_state)
                    else
                        tt = _call_tt_from_raw_args(raw_args, ir)
                        tt === nothing || _mark_budget_hit!(budget_state)
                    end
                end

                if s !== nothing
                    for p in s.ret_aliases
                        push!(alias_args, p)
                    end
                else
                    for p in 2:length(raw_args)
                        push!(alias_args, p)
                    end
                end
            else
                for p in 2:length(raw_args)
                    push!(alias_args, p)
                end
            end

            isempty(alias_args) && continue
            for p in alias_args
                (1 <= p <= length(raw_args)) || continue
                in_h = _handle_index(raw_args[p], nargs, track_arg, track_ssa)
                _uf_union!(uf, out_h, in_h)
            end
        end
    end
    return uf
end

function _used_handles(stmt, nargs::Int, track_arg, track_ssa)
    s = BitSet()
    _collect_used_handles!(s, stmt, nargs, track_arg, track_ssa)
    return s
end

function _collect_used_handles!(s::BitSet, x, nargs::Int, track_arg, track_ssa)
    if x isa Core.Argument || x isa Core.SSAValue
        h = _handle_index(x, nargs, track_arg, track_ssa)
        h != 0 && push!(s, h)
        return nothing
    end
    if x isa Core.ReturnNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.PiNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.UpsilonNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.GotoIfNot
        if isdefined(x, :cond)
            _collect_used_handles!(s, getfield(x, :cond), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Expr
        for a in x.args
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Tuple
        for a in x
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa AbstractArray
        for a in x
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    return nothing
end

function _canonical_ref(@nospecialize(x), ir::CC.IRCode)
    while x isa Core.SSAValue
        stmt = try
            ir[x][:stmt]
        catch
            break
        end
        if stmt isa Core.SSAValue
            x = stmt
            continue
        end
        if stmt isa Core.PiNode
            x = stmt.val
            continue
        end
        break
    end
    return x
end

function _binding_origins(ir::CC.IRCode, cfg::Config, nargs::Int, track_arg, track_ssa)
    nstmts = length(ir.stmts)
    origins = collect(1:(nargs + nstmts))

    # SSA origins: treat plain SSA copies as the same "binding"; everything else
    # gets its own binding id (including __bc_bind__ outputs).
    for idx in 1:nstmts
        track_ssa[idx] || continue
        hdef = _ssa_handle(nargs, idx)
        stmt = ir[Core.SSAValue(idx)][:stmt]

        if stmt isa Core.PiNode
            hsrc = _handle_index(stmt.val, nargs, track_arg, track_ssa)
            origins[hdef] = (hsrc == 0) ? hdef : origins[hsrc]
            continue
        end

        if stmt isa Core.SSAValue || stmt isa Core.Argument
            hsrc = _handle_index(stmt, nargs, track_arg, track_ssa)
            origins[hdef] = (hsrc == 0) ? hdef : origins[hsrc]
            continue
        end

        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            f = _resolve_callee(stmt, ir)
            if f === __bc_bind__ || (isdefined(Base, :inferencebarrier) && f === Base.inferencebarrier)
                origins[hdef] = hdef
                continue
            end
        end

        origins[hdef] = hdef
    end

    return origins
end

function _compute_liveness(ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    blocks = ir.cfg.blocks
    nblocks = length(blocks)

    phi_edge_use = [BitSet() for _ in 1:nblocks]
    use = [BitSet() for _ in 1:nblocks]
    def = [BitSet() for _ in 1:nblocks]

    inst2bb = zeros(Int, length(ir.stmts))
    for b in 1:nblocks
        for idx in blocks[b].stmts
            inst2bb[idx] = b
        end
    end

    # Phi operands are used on edges from predecessor blocks.
    for b in 1:nblocks
        r = blocks[b].stmts
        for idx in r
            stmt = ir[Core.SSAValue(idx)][:stmt]
            if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
                edges = getfield(stmt, :edges)
                vals = getfield(stmt, :values)
                for k in 1:length(edges)
                    edge = edges[k]
                    v = vals[k]
                    h = _handle_index(v, nargs, track_arg, track_ssa)
                    h == 0 && continue
                    pred_bb = 0
                    if 1 <= edge <= length(inst2bb) && inst2bb[edge] != 0
                        pred_bb = inst2bb[edge]
                    elseif 1 <= edge <= nblocks
                        pred_bb = edge
                    end
                    pred_bb == 0 && continue
                    push!(phi_edge_use[pred_bb], h)
                end
            else
                break
            end
        end
    end

    # Block use/def sets.
    for b in 1:nblocks
        seen_defs = BitSet()
        for idx in blocks[b].stmts
            # defs: each statement defines SSAValue(idx)
            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                hdef = _ssa_handle(nargs, idx)
                push!(def[b], hdef)
                push!(seen_defs, hdef)
            end
            stmt = ir[Core.SSAValue(idx)][:stmt]
            # phi operands are handled on edges; skip their uses here.
            if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
                continue
            end
            uses = _used_handles(stmt, nargs, track_arg, track_ssa)
            for u in uses
                if !(u in seen_defs)
                    push!(use[b], u)
                end
            end
        end
    end

    live_in = [BitSet() for _ in 1:nblocks]
    live_out = [BitSet() for _ in 1:nblocks]

    changed = true
    while changed
        changed = false
        for b in nblocks:-1:1
            out = BitSet()
            union!(out, phi_edge_use[b])
            for s in blocks[b].succs
                union!(out, live_in[s])
            end
            inn = BitSet()
            union!(inn, use[b])
            tmp = BitSet(out)
            for d in def[b]
                delete!(tmp, d)
            end
            union!(inn, tmp)
            if out != live_out[b] || inn != live_in[b]
                live_out[b] = out
                live_in[b] = inn
                changed = true
            end
        end
    end

    return live_in, live_out
end

function check_ir(ir::CC.IRCode, cfg::Config)::Vector{BorrowViolation}
    nargs = length(ir.argtypes)
    nstmts = length(ir.stmts)

    track_arg = Vector{Bool}(undef, nargs)
    for a in 1:nargs
        T = try
            CC.widenconst(ir.argtypes[a])
        catch
            Any
        end
        track_arg[a] = is_tracked_type(T)
    end

    track_ssa = Vector{Bool}(undef, nstmts)
    for i in 1:nstmts
        T = try
            inst = ir[Core.SSAValue(i)]
            CC.widenconst(_inst_get(inst, :type, Any))
        catch
            Any
        end
        track_ssa[i] = is_tracked_type(T)
    end

    uf = UnionFind(nargs + nstmts)
    _build_alias_classes!(uf, ir, cfg, track_arg, track_ssa, nargs)
    origins = _binding_origins(ir, cfg, nargs, track_arg, track_ssa)

    live_in, live_out = _compute_liveness(ir, nargs, track_arg, track_ssa)

    viols = BorrowViolation[]

    blocks = ir.cfg.blocks
    for b in 1:length(blocks)
        live = BitSet(live_out[b])
        for idx in reverse(blocks[b].stmts)
            stmt = ir[Core.SSAValue(idx)][:stmt]

            # Uses *during* this statement include live-after plus immediate uses.
            uses = if (stmt isa Core.PhiNode || stmt isa Core.PhiCNode)
                BitSet()
            else
                _used_handles(stmt, nargs, track_arg, track_ssa)
            end
            live_during = BitSet(live)
            union!(live_during, uses)

            # Perform checks.
            _check_stmt!(
                viols,
                ir,
                idx,
                stmt,
                uf,
                origins,
                cfg,
                nargs,
                track_arg,
                track_ssa,
                live,
                live_during,
            )

            # Update liveness for previous statement.
            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                delete!(live, _ssa_handle(nargs, idx))
            end
            union!(live, uses)
        end
    end

    return viols
end

@inline function _call_safe_under_unknown_consume(
    raw_args,
    nargs,
    track_arg,
    track_ssa,
    uf,
    origins,
    live_during::BitSet,
    live_after::BitSet,
)
    for arg in raw_args
        hv = _handle_index(arg, nargs, track_arg, track_ssa)
        hv == 0 && continue

        rv = _uf_find(uf, hv)
        ohv = origins[hv]

        for h2 in live_during
            h2 == hv && continue
            if _uf_find(uf, h2) == rv && origins[h2] != ohv
                return false
            end
        end

        for h2 in live_after
            if _uf_find(uf, h2) == rv
                return false
            end
        end
    end

    return true
end

function _check_stmt!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    origins::AbstractVector{Int},
    cfg::Config,
    nargs::Int,
    track_arg,
    track_ssa,
    live_after::BitSet,
    live_during::BitSet,
)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing

    if stmt isa Expr && stmt.head === :foreigncall
        used = _used_handles(stmt, nargs, track_arg, track_ssa)
        for hv in used
            hv == 0 && continue
            _require_unique!(
                viols,
                ir,
                idx,
                stmt,
                uf,
                origins,
                hv,
                live_during;
                context="write",
            )
        end
        return
    end

    if cfg.unknown_call_policy === :consume &&
        _call_safe_under_unknown_consume(
            raw_args,
            nargs,
            track_arg,
            track_ssa,
            uf,
            origins,
            live_during,
            live_after,
        )
        return
    end

    eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs; idx=idx)

    out_h = (1 <= idx <= length(track_ssa) && track_ssa[idx]) ? _ssa_handle(nargs, idx) : 0

    # Writes require uniqueness (no other live alias).
    for p in eff.writes
        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(
            viols,
            ir,
            idx,
            stmt,
            uf,
            origins,
            hv,
            live_during;
            context="write",
            ignore_h=out_h,
        )
    end

    # Consumes require uniqueness and no later use of any alias in the region.
    for p in eff.consumes
        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(
            viols,
            ir,
            idx,
            stmt,
            uf,
            origins,
            hv,
            live_during;
            context="consume",
        )
        _require_not_used_later!(viols, ir, idx, stmt, uf, origins, hv, live_after)
    end
end

function _require_unique!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    origins::AbstractVector{Int},
    hv::Int,
    live_during::BitSet;
    context::String,
    ignore_h::Int=0,
)
    rv = _uf_find(uf, hv)
    ohv = origins[hv]
    for h2 in live_during
        (h2 == hv || h2 == ignore_h) && continue
        if _uf_find(uf, h2) == rv && origins[h2] != ohv
            li = _stmt_lineinfo(ir, idx)
            push!(
                viols,
                BorrowViolation(
                    idx,
                    "cannot perform $context: value is aliased by another live binding",
                    li,
                    stmt,
                ),
            )
            return nothing
        end
    end
end

function _require_not_used_later!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    origins::AbstractVector{Int},
    hv::Int,
    live_after::BitSet,
)
    rv = _uf_find(uf, hv)
    for h2 in live_after
        if _uf_find(uf, h2) == rv
            li = _stmt_lineinfo(ir, idx)
            push!(
                viols,
                BorrowViolation(
                    idx,
                    "value escapes/consumed by unknown call; it (or an alias) is used later",
                    li,
                    stmt,
                ),
            )
            return nothing
        end
    end
end
