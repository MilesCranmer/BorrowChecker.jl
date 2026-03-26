function _compute_liveness(
    ir::CC.IRCode,
    nargs::Int,
    track_arg,
    track_ssa;
    unsafe_stmt::Union{Nothing,AbstractVector{Bool}}=nothing,
)
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
            if unsafe_stmt !== nothing && unsafe_stmt[idx]
                continue
            end
            stmt = ir[Core.SSAValue(idx)][:stmt]
            if stmt isa Core.PhiNode
                edges = getfield(stmt, :edges)
                vals = getfield(stmt, :values)
                for k in 1:length(edges)
                    isassigned(vals, k) || continue
                    edge = edges[k]
                    v = vals[k]
                    h = _handle_index(v, nargs, track_arg, track_ssa)
                    h == 0 && continue
                    @assert 1 <= edge <= length(inst2bb) && inst2bb[edge] != 0 "Unexpected IR: PhiNode.edges should contain predecessor terminator statement indices (not block IDs)."
                    pred_bb = inst2bb[edge]
                    push!(phi_edge_use[pred_bb], h)
                end
            elseif stmt isa Core.PhiCNode
                # `PhiCNode` does not store explicit `edges` (unlike `PhiNode`).
                # Conservatively attribute each value to predecessor blocks.
                vals = getfield(stmt, :values)
                preds = blocks[b].preds
                @assert length(vals) != length(preds) "Unexpected IR: PhiCNode.values length unexpectedly matches predecessor count."
                for k in 1:length(vals)
                    isassigned(vals, k) || continue
                    v = vals[k]
                    h = _handle_index(v, nargs, track_arg, track_ssa)
                    h == 0 && continue
                    for pred_bb in preds
                        (1 <= pred_bb <= nblocks) || continue
                        push!(phi_edge_use[pred_bb], h)
                    end
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
            if unsafe_stmt !== nothing && unsafe_stmt[idx]
                continue
            end
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

    # Improve local IR typing around Core.Box/captured values and dynamic GlobalRef calls.
    refine_types!(ir, cfg)

    track_arg, track_ssa = compute_tracking_masks(ir)

    # Statements inside `@unsafe` regions are treated as opaque: we do not validate
    # borrow rules within them, and we avoid propagating aliasing/escape facts from
    # within them into the surrounding checked code.
    unsafe_stmt = _unsafe_stmt_mask(ir)

    uf = UnionFind(nargs + nstmts)
    _build_alias_classes!(uf, ir, cfg, track_arg, track_ssa, nargs; unsafe_stmt=unsafe_stmt)
    origins = _binding_origins(ir, nargs, track_arg, track_ssa; unsafe_stmt=unsafe_stmt)

    live_in, live_out = _compute_liveness(
        ir, nargs, track_arg, track_ssa; unsafe_stmt=unsafe_stmt
    )

    viols = BorrowViolation[]

    blocks = ir.cfg.blocks
    for b in 1:length(blocks)
        live = BitSet(live_out[b])
        for idx in reverse(blocks[b].stmts)
            stmt = ir[Core.SSAValue(idx)][:stmt]

            in_unsafe = (1 <= idx <= length(unsafe_stmt)) && unsafe_stmt[idx]

            uses = if in_unsafe || (stmt isa Core.PhiNode || stmt isa Core.PhiCNode)
                BitSet()
            else
                _used_handles(stmt, ir, nargs, track_arg, track_ssa)
            end
            live_during = BitSet(live)
            union!(live_during, uses)

            if !in_unsafe
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
            end

            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                delete!(live, _ssa_handle(nargs, idx))
            end
            union!(live, uses)
        end
    end

    return viols
end

function _method_arg_symbols(ir::CC.IRCode)
    mi = try
        getproperty(getproperty(ir, :debuginfo), :def)
    catch
        nothing
    end
    mi isa Core.MethodInstance || return nothing
    m = try
        getproperty(mi, :def)
    catch
        nothing
    end
    m isa Method || return nothing
    slot_syms = try
        getproperty(m, :slot_syms)
    catch
        nothing
    end
    slot_syms isa AbstractString || return nothing
    names = split(String(slot_syms), '\0'; keepempty=false)
    return names
end

function _handle_var_symbol(ir::CC.IRCode, nargs::Int, hv::Int)::Symbol
    hv == 0 && return :anonymous

    if hv <= nargs
        names = _method_arg_symbols(ir)
        if names !== nothing && hv <= length(names)
            nm = names[hv]
            nm == "#self#" && return :anonymous
            return Symbol(nm)
        end
        return :anonymous
    end

    sid = hv - nargs
    (1 <= sid <= length(ir.stmts)) || return :anonymous
    stmt = try
        ir[Core.SSAValue(sid)][:stmt]
    catch
        nothing
    end
    stmt isa Expr || return :anonymous
    (stmt.head === :call || stmt.head === :invoke) || return :anonymous

    f = _resolve_callee(stmt, ir)
    f === __bc_bind__ || return :anonymous

    length(stmt.args) >= 3 || return :anonymous
    dest = stmt.args[3]
    if dest isa QuoteNode && dest.value isa Symbol
        return dest.value
    elseif dest isa Symbol
        return dest
    end

    return :anonymous
end

function _handle_def_lineinfo(ir::CC.IRCode, nargs::Int, hv::Int)
    if hv > nargs
        sid = hv - nargs
        return _stmt_lineinfo(ir, sid)
    end

    mi = try
        getproperty(getproperty(ir, :debuginfo), :def)
    catch
        nothing
    end
    mi isa Core.MethodInstance || return nothing
    m = try
        getproperty(mi, :def)
    catch
        nothing
    end
    m isa Method || return nothing

    file = getproperty(m, :file)
    line = getproperty(m, :line)
    file isa Symbol || return nothing
    line isa Integer || return nothing
    return LineNumberNode(Int(line), file)
end

function _quoted_var(sym::Symbol)
    return sym === :anonymous ? "value" : "`$(sym)`"
end

function _alias_conflict_msg(
    context::String, problem_var::Symbol, other_var::Symbol
)::String
    lhs = _quoted_var(problem_var)
    rhs = other_var === :anonymous ? "another live binding" : "`$(other_var)`"
    return "cannot perform $context: $(lhs) is aliased by $(rhs)"
end

function _args_safe_under_unknown_consume(
    args, nargs, track_arg, track_ssa, uf, origins, live_during::BitSet, live_after::BitSet
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

function _call_safe_under_unknown_consume(
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

function _push_violation!(
    viols::Vector{BorrowViolation},
    ir::CC.IRCode,
    idx::Int,
    stmt,
    msg::String;
    kind::Symbol=:generic,
    problem_var::Symbol=:anonymous,
    other_var::Symbol=:anonymous,
    other_lineinfo=nothing,
    problem_argpos::Int=0,
)
    li = _stmt_lineinfo(ir, idx)
    push!(
        viols,
        BorrowViolation(
            idx, msg, li, stmt, kind, problem_var, other_var, other_lineinfo, problem_argpos
        ),
    )
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
    if stmt isa Expr && stmt.head === :foreigncall
        name_sym, ccall_args, _gc_roots, _nccallargs = _foreigncall_parts(stmt)
        eff = (name_sym === nothing) ? nothing : _known_foreigncall_effects_get(name_sym)

        out_h =
            (1 <= idx <= length(track_ssa) && track_ssa[idx]) ? _ssa_handle(nargs, idx) : 0

        # Enforce uniqueness for each alias-root touched by `group_handles`,
        # but allow any binding origins that arise within the same group.
        function require_unique_group!(group_handles::BitSet; context::String)
            roots_allowed = Dict{Int,BitSet}()
            reps = Dict{Int,Int}()

            for hv in group_handles
                hv == 0 && continue
                hroot = _uf_find(uf, hv)
                allowed = get!(roots_allowed, hroot, BitSet())
                push!(allowed, origins[hv])
                reps[hroot] = get(reps, hroot, hv)
            end

            for (hroot, allowed) in roots_allowed
                best_h2 = 0
                best_other_var = :anonymous
                for h2 in live_during
                    (h2 == out_h) && continue
                    (h2 == 1) && continue
                    if _uf_find(uf, h2) == hroot && !(origins[h2] in allowed)
                        cand_other_var = _handle_var_symbol(ir, nargs, h2)
                        if best_h2 == 0 ||
                            (best_other_var == :anonymous && cand_other_var != :anonymous)
                            best_h2 = h2
                            best_other_var = cand_other_var
                        end
                    end
                end
                if best_h2 != 0
                    rep = reps[hroot]
                    problem_var = _handle_var_symbol(ir, nargs, rep)
                    other_li = _handle_def_lineinfo(ir, nargs, best_h2)
                    _push_violation!(
                        viols,
                        ir,
                        idx,
                        stmt,
                        _alias_conflict_msg(context, problem_var, best_other_var);
                        kind=:alias_conflict,
                        problem_var,
                        other_var=best_other_var,
                        other_lineinfo=other_li,
                    )
                    return reps
                end
            end

            return reps
        end

        # Unknown foreigncall: keep old conservative behavior.
        if eff === nothing
            # Treat as write to the C arguments only (ignore GC roots), but allow redundant
            # `(obj, ptr, ...)` argument representations to coexist within the call.
            hs_all = BitSet()
            for v in ccall_args
                hs = _backward_used_handles(v, ir, nargs, track_arg, track_ssa)
                union!(hs_all, hs)
            end
            require_unique_group!(hs_all; context="write")
            return nothing
        end

        for grp in eff.write_groups
            hs = _foreigncall_group_used_handles(
                ccall_args, grp, ir, nargs, track_arg, track_ssa
            )
            require_unique_group!(hs; context="write")
        end

        for grp in eff.consume_groups
            hs = _foreigncall_group_used_handles(
                ccall_args, grp, ir, nargs, track_arg, track_ssa
            )
            reps = require_unique_group!(hs; context="consume")
            for (_, rep) in reps
                _require_not_used_later!(viols, ir, idx, stmt, uf, origins, rep, live_after)
            end
        end

        return nothing
    end

    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing

    f = _resolve_callee(stmt, ir)
    kw_vals = (f === Core.kwcall) ? _kwcall_value_exprs(stmt, ir) : nothing
    (kw_vals === nothing || isempty(kw_vals)) && (kw_vals = nothing)

    eff = _effects_for_call(stmt, ir, cfg, track_arg, track_ssa, nargs; idx=idx)
    moved_positions = _moved_positions_for_eval_order_check(f, raw_args, eff, ir)
    _check_call_eval_order_moves!(
        viols, ir, idx, stmt, uf, moved_positions, raw_args, nargs, track_arg, track_ssa
    )

    if _call_safe_under_unknown_consume(
        raw_args, kw_vals, nargs, track_arg, track_ssa, uf, origins, live_during, live_after
    )
        return nothing
    end

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

function _moved_positions_for_eval_order_check(
    @nospecialize(f), raw_args, eff::EffectSummary, ir::CC.IRCode
)::BitSet
    # For most calls, use the effect summary's consume set.
    # Special case: tuple construction should not allow using the same owned value
    # in later elements after it has already been used in an earlier element.
    if f === Core.tuple
        # Ignore empty / 1-element tuples (these show up in compiler plumbing, e.g. splat containers).
        length(raw_args) <= 2 && return BitSet()

        moved = BitSet()
        for p in 2:length(raw_args)
            Tv = _widenargtype_or_any(raw_args[p], ir)
            is_owned_type(Tv) || continue
            push!(moved, p)
        end
        return moved
    end

    return eff.consumes
end

function _check_call_eval_order_moves!(
    viols,
    ir::CC.IRCode,
    idx::Int,
    stmt,
    uf::UnionFind,
    moved_positions::BitSet,
    raw_args,
    nargs::Int,
    track_arg,
    track_ssa,
)
    isempty(moved_positions) && return nothing

    for p in moved_positions
        # raw_args[1] is the function value; treat only user arguments as moved values.
        p >= 2 || continue
        p <= length(raw_args) || continue

        vp = raw_args[p]
        hp = _handle_index(vp, nargs, track_arg, track_ssa)
        hp == 0 && continue

        rp = _uf_find(uf, hp)

        for q in (p + 1):length(raw_args)
            deps = _backward_used_handles(raw_args[q], ir, nargs, track_arg, track_ssa)
            for hq in deps
                _uf_find(uf, hq) == rp || continue
                problem_var = _handle_var_symbol(ir, nargs, hp)
                problem_var === :anonymous &&
                    (problem_var = _handle_var_symbol(ir, nargs, hq))
                msg =
                    "call argument uses $(_quoted_var(problem_var)) after it was moved by an earlier argument " *
                    "(arg $p before arg $q)"
                _push_violation!(
                    viols,
                    ir,
                    idx,
                    stmt,
                    msg;
                    kind=:eval_order_use_after_move,
                    problem_var,
                    problem_argpos=q,
                )
                return nothing
            end
        end
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
    nargs = length(ir.argtypes)
    rv = _uf_find(uf, hv)
    ohv = origins[hv]
    best_h2 = 0
    best_other_var = :anonymous
    for h2 in live_during
        (h2 == hv || h2 == ignore_h || h2 == 1) && continue
        if _uf_find(uf, h2) == rv && origins[h2] != ohv
            cand_other_var = _handle_var_symbol(ir, nargs, h2)
            if best_h2 == 0 ||
                (best_other_var == :anonymous && cand_other_var != :anonymous)
                best_h2 = h2
                best_other_var = cand_other_var
            end
        end
    end
    best_h2 == 0 && return nothing

    problem_var = _handle_var_symbol(ir, nargs, hv)
    other_li = _handle_def_lineinfo(ir, nargs, best_h2)
    _push_violation!(
        viols,
        ir,
        idx,
        stmt,
        _alias_conflict_msg(context, problem_var, best_other_var);
        kind=:alias_conflict,
        problem_var,
        other_var=best_other_var,
        other_lineinfo=other_li,
    )
    return nothing
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
    nargs = length(ir.argtypes)
    rv = _uf_find(uf, hv)
    best_h2 = 0
    best_other_var = :anonymous
    for h2 in live_after
        _uf_find(uf, h2) == rv || continue

        cand_other_var = _handle_var_symbol(ir, nargs, h2)
        if best_h2 == 0 || (best_other_var == :anonymous && cand_other_var != :anonymous)
            best_h2 = h2
            best_other_var = cand_other_var
        end
    end

    best_h2 == 0 && return nothing

    problem_var = _handle_var_symbol(ir, nargs, hv)
    other_li = _handle_def_lineinfo(ir, nargs, best_h2)
    msg = if best_other_var === :anonymous
        "value escapes/consumed by unknown call; it (or an alias) is used later"
    else
        "value escapes/consumed by unknown call: $(_quoted_var(problem_var)) is later used via `$(best_other_var)`"
    end
    _push_violation!(
        viols,
        ir,
        idx,
        stmt,
        msg;
        kind=:unknown_consume_later_use,
        problem_var,
        other_var=best_other_var,
        other_lineinfo=other_li,
    )
    return nothing
end
