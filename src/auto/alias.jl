@inline _field_sym(x) = x isa QuoteNode ? x.value : x

function _box_key(@nospecialize(box), ir::CC.IRCode, nargs::Int)::Int
    box = _canonical_ref(box, ir)
    if box isa Core.Argument
        return box.n
    elseif box isa Core.SSAValue
        return _ssa_handle(nargs, box.id)
    end
    return 0
end

function _maybe_record_box_contents!(
    box_contents::Dict{Int,Int},
    @nospecialize(f),
    raw_args,
    ir::CC.IRCode,
    nargs::Int,
    track_arg,
    track_ssa,
)
    f === Core.setfield! || return nothing
    length(raw_args) >= 4 || return nothing

    _field_sym(raw_args[3]) === :contents || return nothing

    key = _box_key(raw_args[2], ir, nargs)
    key == 0 && return nothing

    vh = _handle_index(raw_args[4], nargs, track_arg, track_ssa)
    vh == 0 && return nothing

    box_contents[key] = vh
    return nothing
end

function _maybe_alias_box_contents!(
    uf::UnionFind,
    out_h::Int,
    box_contents::Dict{Int,Int},
    @nospecialize(f),
    raw_args,
    ir::CC.IRCode,
    nargs::Int,
)
    f === Core.getfield || return nothing
    length(raw_args) >= 3 || return nothing

    _field_sym(raw_args[3]) === :contents || return nothing

    key = _box_key(raw_args[2], ir, nargs)
    key == 0 && return nothing

    in_h = get(box_contents, key, 0)
    in_h == 0 && return nothing

    _uf_union!(uf, out_h, in_h)
    return nothing
end

function _push_all_user_args!(dest::Vector{Int}, raw_args)
    for p in 2:length(raw_args)
        push!(dest, p)
    end
    return dest
end

function _maybe_ret_alias_summary(
    stmt,
    ir::CC.IRCode,
    cfg::Config,
    @nospecialize(f),
    raw_args;
    depth::Int,
    budget_state=nothing,
)
    if depth < cfg.max_summary_depth
        if stmt.head === :invoke
            return _summary_for_mi(
                stmt.args[1], cfg; depth=depth + 1, budget_state=budget_state
            )
        end

        if f === Core.kwcall
            tt = _kwcall_tt_from_raw_args(raw_args, ir)
            tt !== nothing && return _summary_for_tt(
                tt, cfg; depth=depth + 1, budget_state=budget_state, allow_core=true
            )
            return nothing
        end

        tt = _call_tt_from_raw_args(raw_args, ir)
        tt !== nothing &&
            return _summary_for_tt(tt, cfg; depth=depth + 1, budget_state=budget_state)
        return nothing
    end

    if stmt.head === :invoke
        _mark_budget_hit!(budget_state)
    else
        tt = if f === Core.kwcall
            _kwcall_tt_from_raw_args(raw_args, ir)
        else
            _call_tt_from_raw_args(raw_args, ir)
        end
        tt === nothing || _mark_budget_hit!(budget_state)
    end

    return nothing
end

function _ret_alias_positions_for_call(
    stmt,
    ir::CC.IRCode,
    cfg::Config,
    @nospecialize(f),
    raw_args;
    depth::Int,
    budget_state=nothing,
)
    alias_args = Int[]

    if f !== nothing
        eff = _known_effects_get(f)
        if eff !== nothing
            for p in eff.ret_aliases
                push!(alias_args, p)
            end
            return alias_args
        end
    end

    s = _maybe_ret_alias_summary(
        stmt, ir, cfg, f, raw_args; depth=depth, budget_state=budget_state
    )
    if s !== nothing
        for p in s.ret_aliases
            push!(alias_args, p)
        end
        return alias_args
    end
    return _push_all_user_args!(alias_args, raw_args)
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

        if stmt isa Core.PiNode
            in_h = _handle_index(stmt.val, nargs, track_arg, track_ssa)
            _uf_union!(uf, out_h, in_h)
            continue
        end

        if stmt isa Core.PhiNode || stmt isa Core.PhiCNode
            vals = getfield(stmt, :values)
            for v in vals
                in_h = _handle_index(v, nargs, track_arg, track_ssa)
                _uf_union!(uf, out_h, in_h)
            end
            continue
        end

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

        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            raw_args = (stmt.head === :invoke) ? stmt.args[2:end] : stmt.args
            f = _resolve_callee(stmt, ir)

            # Tuples are immutable containers. We intentionally do NOT union tuples with all
            # tracked elements (that would incorrectly merge distinct tracked values).
            # However, a common compiler pattern is to return a tuple that contains exactly
            # one tracked value (e.g. `(ptr, stride)`), which is then immediately projected
            # with `getfield` / `indexed_iterate`. In that case we conservatively union the
            # tuple with that single tracked element so effects can flow through the
            # intermediate tuple value.
            if f === Core.tuple
                only_h = 0
                for p in 2:length(raw_args)
                    in_h = _handle_index(raw_args[p], nargs, track_arg, track_ssa)
                    in_h == 0 && continue
                    if only_h == 0
                        only_h = in_h
                    else
                        only_h = -1
                        break
                    end
                end
                (only_h > 0) && _uf_union!(uf, out_h, only_h)
                continue
            end

            if f !== nothing && _is_namedtuple_ctor(f)
                continue
            end

            _maybe_record_box_contents!(
                box_contents, f, raw_args, ir, nargs, track_arg, track_ssa
            )
            _maybe_alias_box_contents!(uf, out_h, box_contents, f, raw_args, ir, nargs)

            alias_args = _ret_alias_positions_for_call(
                stmt, ir, cfg, f, raw_args; depth=depth, budget_state=budget_state
            )

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

function _binding_origins(ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    nstmts = length(ir.stmts)
    origins = collect(1:(nargs + nstmts))

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
            if f === __bc_bind__ ||
                (isdefined(Base, :inferencebarrier) && f === Base.inferencebarrier)
                # Binding barriers are treated as producing a fresh identity for tracking.
                origins[hdef] = hdef
                continue
            end
        end

        origins[hdef] = hdef
    end

    return origins
end
