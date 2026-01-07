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

function _effects_for_call(
    stmt, ir::CC.IRCode, cfg::Config, track_arg, track_ssa, nargs::Int; depth::Int=0
)::EffectSummary
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return EffectSummary()
    f = _resolve_callee(stmt, ir)

    # Our own internal helpers are treated as pure.
    if f === __bc_bind__
        return EffectSummary()
    end

    # Table overrides.
    if f !== nothing && haskey(_known_effects, f)
        return _known_effects[f]
    end

    # If we have a statically resolved method instance, we can optionally summarize it.
    if head === :invoke &&
        cfg.analyze_invokes &&
        (mi !== nothing) &&
        depth < cfg.max_summary_depth
        s = _summary_for_mi(mi, cfg; depth=depth + 1)
        if s !== nothing
            return s
        end
    end

    # Heuristic convention for known constant callees.
    if f !== nothing
        nm = _callee_name_str(f)
        if cfg.assume_bang_mutates && endswith(nm, "!")
            return EffectSummary(; writes=[2])
        elseif cfg.assume_nonbang_readonly
            return EffectSummary()
        end
    end

    # Unknown call policy.
    if cfg.unknown_call_policy === :consume
        consumes = Int[]
        for p in 2:length(raw_args)
            h = _handle_index(raw_args[p], nargs, track_arg, track_ssa)
            h == 0 && continue
            push!(consumes, p)
        end
        return EffectSummary(; consumes=consumes)
    else
        return EffectSummary()
    end
end

function _summary_for_mi(mi, cfg::Config; depth::Int)
    # Avoid summarizing Base/Core in this MVP: it's huge and unstable across versions.
    try
        if mi isa Core.MethodInstance
            m = mi.def
            if (m isa Method) &&
                (m.module === Base || m.module === Core || m.module === Experimental)
                return nothing
            end
        end
    catch
        # if reflection fails, just skip
        return nothing
    end

    lock(_lock) do
        if haskey(_summary_cache, mi)
            return _summary_cache[mi]
        end
    end

    # Compute summary without holding the lock (avoid deadlocks during reflection/inference).
    summ = nothing
    try
        tt = mi.specTypes
        world = Base.get_world_counter()
        codes = Base.code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        # Pick the first IRCode we get (should usually be 1).
        for entry in codes
            ir = entry.first
            ir isa CC.IRCode || continue
            summ = _summarize_ir_effects(ir, cfg; depth=depth)
            break
        end
    catch
        summ = nothing
    end

    if summ !== nothing
        lock(_lock) do
            _summary_cache[mi] = summ
        end
    end
    return summ
end

function _summarize_ir_effects(ir::CC.IRCode, cfg::Config; depth::Int)::EffectSummary
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
    _build_alias_classes!(uf, ir, cfg, track_arg, track_ssa, nargs; depth=depth)

    writes = BitSet()
    consumes = BitSet()

    for i in 1:nstmts
        stmt = ir[Core.SSAValue(i)][:stmt]
        head, _mi, raw_args = _call_parts(stmt)
        raw_args === nothing && continue

        eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs; depth=depth)

        # Map actual argument positions back to formal arguments by alias class.
        for p in eff.writes
            p < 2 && continue
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
            p < 2 && continue
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

    return EffectSummary(; writes=writes, consumes=consumes)
end

function _build_alias_classes!(
    uf::UnionFind,
    ir::CC.IRCode,
    cfg::Config,
    track_arg,
    track_ssa,
    nargs::Int;
    depth::Int=0,
)
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

        # Calls: determine whether return aliases args.
        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            raw_args = (stmt.head === :invoke) ? stmt.args[2:end] : stmt.args
            f = _resolve_callee(stmt, ir)

            # Fresh return overrides.
            if f !== nothing && get(_fresh_return, f, false)
                continue
            end

            style = if f === nothing
                :all
            elseif haskey(_ret_alias, f)
                _ret_alias[f]
            else
                nm = _callee_name_str(f)
                (cfg.assume_bang_mutates && endswith(nm, "!")) ? :arg1 : :none
            end
            style === :none && continue

            if style === :arg1
                if length(raw_args) >= 2
                    in_h = _handle_index(raw_args[2], nargs, track_arg, track_ssa)
                    _uf_union!(uf, out_h, in_h)
                end
            else
                # Conservative default: return may alias any tracked arg.
                for p in 2:length(raw_args)
                    in_h = _handle_index(raw_args[p], nargs, track_arg, track_ssa)
                    _uf_union!(uf, out_h, in_h)
                end
            end
        end
    end
    return uf
end

function _used_handles(stmt, nargs::Int, track_arg, track_ssa)
    s = BitSet()
    for ur in CC.userefs(stmt)
        x = ur[]
        h = _handle_index(x, nargs, track_arg, track_ssa)
        h == 0 && continue
        push!(s, h)
    end
    return s
end

function _compute_liveness(ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    blocks = ir.cfg.blocks
    nblocks = length(blocks)

    phi_edge_use = [BitSet() for _ in 1:nblocks]
    use = [BitSet() for _ in 1:nblocks]
    def = [BitSet() for _ in 1:nblocks]

    # Phi operands are used on edges from predecessor blocks.
    for b in 1:nblocks
        r = blocks[b].stmts
        for idx in r
            stmt = ir[Core.SSAValue(idx)][:stmt]
            if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
                edges = getfield(stmt, :edges)
                vals = getfield(stmt, :values)
                for k in 1:length(edges)
                    pred = edges[k]
                    v = vals[k]
                    h = _handle_index(v, nargs, track_arg, track_ssa)
                    h == 0 && continue
                    if 1 <= pred <= nblocks
                        push!(phi_edge_use[pred], h)
                    end
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

function _check_stmt!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    cfg::Config,
    nargs::Int,
    track_arg,
    track_ssa,
    live_after::BitSet,
    live_during::BitSet,
)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing

    eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs)

    # Writes require uniqueness (no other live alias).
    for p in eff.writes
        p < 2 && continue
        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(viols, ir, idx, stmt, uf, hv, live_during; context="write")
    end

    # Consumes require uniqueness and no later use of any alias in the region.
    for p in eff.consumes
        p < 2 && continue
        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(viols, ir, idx, stmt, uf, hv, live_during; context="consume")
        _require_not_used_later!(viols, ir, idx, stmt, uf, hv, live_after)
    end
end

function _require_unique!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    hv::Int,
    live_during::BitSet;
    context::String,
)
    rv = _uf_find(uf, hv)
    for h2 in live_during
        h2 == hv && continue
        if _uf_find(uf, h2) == rv
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
    viols, ir::CC.IRCode, idx::Int, stmt, uf::UnionFind, hv::Int, live_after::BitSet
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
