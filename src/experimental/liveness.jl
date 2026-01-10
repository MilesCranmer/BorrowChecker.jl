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
