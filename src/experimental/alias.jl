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

            if f !== nothing && _is_namedtuple_ctor(f)
                continue
            end

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
                        s = _summary_for_mi(
                            stmt.args[1], cfg; depth=depth + 1, budget_state=budget_state
                        )
                    else
                        if f === Core.kwcall
                            tt = _kwcall_tt_from_raw_args(raw_args, ir)
                            tt !== nothing && (
                                s = _summary_for_tt(
                                    tt,
                                    cfg;
                                    depth=depth + 1,
                                    budget_state=budget_state,
                                    allow_core=true,
                                )
                            )
                        else
                            tt = _call_tt_from_raw_args(raw_args, ir)
                            tt !== nothing && (
                                s = _summary_for_tt(
                                    tt, cfg; depth=depth + 1, budget_state=budget_state
                                )
                            )
                        end
                    end
                else
                    if stmt.head === :invoke
                        _mark_budget_hit!(budget_state)
                    else
                        tt = if (f === Core.kwcall)
                            _kwcall_tt_from_raw_args(raw_args, ir)
                        else
                            _call_tt_from_raw_args(raw_args, ir)
                        end
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

function _binding_origins(
    ir::CC.IRCode,
    nargs::Int,
    track_arg,
    track_ssa;
    copy_is_new_binding::Bool=false,
)
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
            if copy_is_new_binding
                origins[hdef] = hdef
            else
                hsrc = _handle_index(stmt, nargs, track_arg, track_ssa)
                origins[hdef] = (hsrc == 0) ? hdef : origins[hsrc]
            end
            continue
        end

        if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
            f = _resolve_callee(stmt, ir)
            if f === __bc_bind__ ||
                (isdefined(Base, :inferencebarrier) && f === Base.inferencebarrier)
                origins[hdef] = hdef
                continue
            end
        end

        origins[hdef] = hdef
    end

    return origins
end
