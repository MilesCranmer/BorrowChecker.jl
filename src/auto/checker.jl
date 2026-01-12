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

    for b in 1:nblocks
        seen_defs = BitSet()
        for idx in blocks[b].stmts
            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                hdef = _ssa_handle(nargs, idx)
                push!(def[b], hdef)
                push!(seen_defs, hdef)
            end
            stmt = ir[Core.SSAValue(idx)][:stmt]
            if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
                continue
            end
            uses = _used_handles(stmt, ir, nargs, track_arg, track_ssa)
            for u in uses
                (u in seen_defs) || push!(use[b], u)
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

    track_arg, track_ssa = compute_tracking_masks(ir)

    uf = UnionFind(nargs + nstmts)
    _build_alias_classes!(uf, ir, cfg, track_arg, track_ssa, nargs)
    origins = _binding_origins(ir, nargs, track_arg, track_ssa)

    live_in, live_out = _compute_liveness(ir, nargs, track_arg, track_ssa)

    viols = BorrowViolation[]

    blocks = ir.cfg.blocks
    for b in 1:length(blocks)
        live = BitSet(live_out[b])
        for idx in reverse(blocks[b].stmts)
            stmt = ir[Core.SSAValue(idx)][:stmt]

            uses = if (stmt isa Core.PhiNode || stmt isa Core.PhiCNode)
                BitSet()
            else
                _used_handles(stmt, ir, nargs, track_arg, track_ssa)
            end
            live_during = BitSet(live)
            union!(live_during, uses)

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

            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                delete!(live, _ssa_handle(nargs, idx))
            end
            union!(live, uses)
        end
    end

    return viols
end

@inline function _args_safe_under_unknown_consume(
    args,
    nargs,
    track_arg,
    track_ssa,
    uf,
    origins,
    live_during::BitSet,
    live_after::BitSet,
)::Bool
    for arg in args
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

@inline function _call_safe_under_unknown_consume(
    raw_args,
    extra_args,
    nargs,
    track_arg,
    track_ssa,
    uf,
    origins,
    live_during::BitSet,
    live_after::BitSet,
)
    _args_safe_under_unknown_consume(
        raw_args, nargs, track_arg, track_ssa, uf, origins, live_during, live_after
    ) || return false

    extra_args === nothing && return true

    return _args_safe_under_unknown_consume(
        extra_args, nargs, track_arg, track_ssa, uf, origins, live_during, live_after
    )
end

@inline function _push_violation!(
    viols::Vector{BorrowViolation},
    ir::CC.IRCode,
    idx::Int,
    stmt,
    msg::String,
)
    li = _stmt_lineinfo(ir, idx)
    push!(viols, BorrowViolation(idx, msg, li, stmt))
    return nothing
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
        used = _used_handles(stmt, ir, nargs, track_arg, track_ssa)
        for hv in used
            hv == 0 && continue
            _require_unique!(
                viols, ir, idx, stmt, uf, origins, hv, live_during; context="write"
            )
        end
        return nothing
    end

    f = _resolve_callee(stmt, ir)
    kw_vals = (f === Core.kwcall) ? _kwcall_value_exprs(stmt, ir) : nothing
    (kw_vals === nothing || isempty(kw_vals)) && (kw_vals = nothing)

    if cfg.unknown_call_policy === :consume && _call_safe_under_unknown_consume(
        raw_args, kw_vals, nargs, track_arg, track_ssa, uf, origins, live_during, live_after
    )
        return nothing
    end

    eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs; idx=idx)

    out_h = (1 <= idx <= length(track_ssa) && track_ssa[idx]) ? _ssa_handle(nargs, idx) : 0

    for p in eff.writes
        if f === Core.kwcall && p == 2 && kw_vals !== nothing
            for vkw in kw_vals
                hv = _handle_index(vkw, nargs, track_arg, track_ssa)
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
            continue
        end

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

    for p in eff.consumes
        if f === Core.kwcall && p == 2 && kw_vals !== nothing
            for vkw in kw_vals
                hv = _handle_index(vkw, nargs, track_arg, track_ssa)
                hv == 0 && continue
                _require_unique!(
                    viols, ir, idx, stmt, uf, origins, hv, live_during; context="consume"
                )
                _require_not_used_later!(viols, ir, idx, stmt, uf, origins, hv, live_after)
            end
            continue
        end

        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(
            viols, ir, idx, stmt, uf, origins, hv, live_during; context="consume"
        )
        _require_not_used_later!(viols, ir, idx, stmt, uf, origins, hv, live_after)
    end

    return nothing
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
            _push_violation!(
                viols,
                ir,
                idx,
                stmt,
                "cannot perform $context: value is aliased by another live binding",
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
            _push_violation!(
                viols,
                ir,
                idx,
                stmt,
                "value escapes/consumed by unknown call; it (or an alias) is used later",
            )
            return nothing
        end
    end
end
