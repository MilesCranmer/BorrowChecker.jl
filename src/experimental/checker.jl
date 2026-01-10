function check_ir(ir::CC.IRCode, cfg::Config)::Vector{BorrowViolation}
    nargs = length(ir.argtypes)
    nstmts = length(ir.stmts)

    track_arg, track_ssa = compute_tracking_masks(ir)

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

            uses = if (stmt isa Core.PhiNode || stmt isa Core.PhiCNode)
                BitSet()
            else
                _used_handles(stmt, nargs, track_arg, track_ssa)
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
                viols, ir, idx, stmt, uf, origins, hv, live_during; context="write"
            )
        end
        return nothing
    end

    if cfg.unknown_call_policy === :consume && _call_safe_under_unknown_consume(
        raw_args, nargs, track_arg, track_ssa, uf, origins, live_during, live_after
    )
        return nothing
    end

    eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs; idx=idx)

    out_h = (1 <= idx <= length(track_ssa) && track_ssa[idx]) ? _ssa_handle(nargs, idx) : 0

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

    for p in eff.consumes
        v = raw_args[p]
        hv = _handle_index(v, nargs, track_arg, track_ssa)
        hv == 0 && continue
        _require_unique!(
            viols, ir, idx, stmt, uf, origins, hv, live_during; context="consume"
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

