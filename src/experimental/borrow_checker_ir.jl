
export @borrow_checker, Config, DEFAULT_CONFIG, BorrowCheckError,
       register_effects!, register_fresh_return!, register_return_alias!

import Core.Compiler
const CC = Core.Compiler

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

"Return the name of an `optimize_until` pass before inlining, if available."
function _default_optimize_until()
    if isdefined(CC, :ALL_PASS_NAMES)
        # Prefer a stage early enough that calls haven't been DCE'd away yet.
        # This keeps higher-order call sites (`f(x)`) visible so we can apply
        # `unknown_call_policy` conservatively.
        for nm in CC.ALL_PASS_NAMES
            s = lowercase(String(nm))
            if occursin("slot2reg", s)
                return nm
            end
        end
        for nm in CC.ALL_PASS_NAMES
            s = lowercase(String(nm))
            if occursin("compact_1", s) || occursin("compact 1", s) || occursin("compact1", s)
                return nm
            end
        end
    end
    return nothing
end

Base.@kwdef struct Config
    "Which compiler pass to stop at when fetching IR (`Base.code_ircode_by_type`)."
    optimize_until::Union{String,Int,Nothing} = _default_optimize_until()

    """
    Policy for calls where we cannot determine a safe effect summary.

    * `:consume`  -> treat tracked arguments as *consumed*: they must be unique at the call site
                    and must not be used afterwards.
    * `:ignore`   -> do not enforce anything for unknown calls (NOT recommended; unsound).
    """
    unknown_call_policy::Symbol = :consume

    """
    If true, then for a *known constant callee* we assume the Julia naming convention:

    * `f!` may mutate its first non-function argument (position 2 in the SSA call arglist).
    """
    assume_bang_mutates::Bool = true

    """
    If true, then for a *known constant callee* with a name that does NOT end in `!`,
    we assume it does not mutate arguments.
    """
    assume_nonbang_readonly::Bool = true

    """
    If true, attempt to infer effects for `:invoke` calls by recursively summarizing
    the callee's `IRCode` (skipping Base/Core by default).
    """
    analyze_invokes::Bool = true

    "Max depth for recursive effect summarization."
    max_summary_depth::Int = 6
end

const DEFAULT_CONFIG = Config()

# -----------------------------------------------------------------------------
# Marker intrinsics (inserted by the macro)
# -----------------------------------------------------------------------------

"""
Marker inserted on RHS of (most) assignments inside `@borrow_checker` functions.

It is semantically the identity, but it preserves a distinct SSA value so we can
reconstruct aliasing between bindings even after SSA conversion.
"""
@inline __bc_bind__(x) = x

# -----------------------------------------------------------------------------
# User-extensible effect/alias tables
# -----------------------------------------------------------------------------

struct EffectSummary
    # Indices are in the *raw call argument list* used by the SSA form:
    # raw_args[1] is the function value, raw_args[2] is the first user argument, etc.
    writes::BitSet    # arguments that may be mutated during the call
    consumes::BitSet  # arguments that may escape/need to be treated as consumed
end
EffectSummary(; writes=Int[], consumes=Int[]) = EffectSummary(BitSet(writes), BitSet(consumes))

const _known_effects = IdDict{Any,EffectSummary}()

"Whether a call's return value is known to be fresh (non-aliasing) wrt arguments."
const _fresh_return = IdDict{Any,Bool}()

"""
Return-aliasing style for calls that return a *tracked* value.

* `:none`  -> assume return is fresh wrt arguments
* `:arg1`  -> return aliases the first user argument (raw_args[2])
* `:all`   -> return may alias any tracked argument (conservative default)
"""
const _ret_alias = IdDict{Any,Symbol}()

function register_effects!(f; writes::AbstractVector{<:Integer}=Int[], consumes::AbstractVector{<:Integer}=Int[])
    _known_effects[f] = EffectSummary(writes=collect(Int, writes), consumes=collect(Int, consumes))
    return f
end

function register_fresh_return!(f, fresh::Bool=true)
    _fresh_return[f] = fresh
    return f
end

function register_return_alias!(f, style::Symbol)
    @assert style in (:none, :arg1, :all)
    _ret_alias[f] = style
    return f
end

# Populate minimal defaults.
function __init__()
    # Our own marker is pure and returns arg1 alias.
    register_effects!(__bc_bind__)
    register_return_alias!(__bc_bind__, :arg1)

    # Common aliasing utilities
    if isdefined(Base, :identity)
        register_effects!(Base.identity)
        register_return_alias!(Base.identity, :arg1)
    end
    if isdefined(Core, :typeassert)
        register_effects!(Core.typeassert)
        register_return_alias!(Core.typeassert, :arg1)
    end
    if isdefined(Base, :getproperty)
        register_effects!(Base.getproperty)
        register_return_alias!(Base.getproperty, :arg1)
    end
    if isdefined(Core, :getfield)
        register_effects!(Core.getfield)
        register_return_alias!(Core.getfield, :arg1)
    end

    # Fresh-returning copy operations
    if isdefined(Base, :copy)
        register_effects!(Base.copy)
        register_fresh_return!(Base.copy, true)
        register_return_alias!(Base.copy, :none)
    end
    if isdefined(Base, :deepcopy)
        register_effects!(Base.deepcopy)
        register_fresh_return!(Base.deepcopy, true)
        register_return_alias!(Base.deepcopy, :none)
    end

    # Core mutators (by convention write arg1)
    if isdefined(Base, :setindex!)
        register_effects!(Base.setindex!; writes=[2])
        register_return_alias!(Base.setindex!, :arg1)
    end
    if isdefined(Core, :setfield!)
        register_effects!(Core.setfield!; writes=[2])
        register_return_alias!(Core.setfield!, :arg1)
    end

    # A few common Base mutators
    for nm in (:push!, :pushfirst!, :pop!, :popfirst!, :append!, :empty!, :resize!, :sizehint!, :fill!, :sort!, :reverse!, :copyto!)
        if isdefined(Base, nm)
            f = getfield(Base, nm)
            register_effects!(f; writes=[2])
            register_return_alias!(f, :arg1)
        end
    end
end

# -----------------------------------------------------------------------------
# Errors & diagnostics
# -----------------------------------------------------------------------------

struct BorrowViolation
    idx::Int
    msg::String
    lineinfo::Union{Nothing,Any}
    stmt::Any
end

struct BorrowCheckError <: Exception
    tt::Any
    violations::Vector{BorrowViolation}
end

function Base.showerror(io::IO, e::BorrowCheckError)
    println(io, "BorrowCheckError for specialization ", e.tt)
    for (k, v) in enumerate(e.violations)
        println(io)
        println(io, "  [", k, "] stmt#", v.idx, ": ", v.msg)
        if v.lineinfo !== nothing
            println(io, "      ", v.lineinfo)
        end
        try
            s = sprint(show, v.stmt)
            if length(s) > 240
                s = s[1:240] * "…"
            end
            println(io, "      stmt: ", s)
        catch
            # ignore printing failures
        end
    end
end

# -----------------------------------------------------------------------------
# Caches
# -----------------------------------------------------------------------------

const _checked_cache = IdDict{Any,UInt}()            # Type{Tuple...} => world
const _summary_cache = IdDict{Any,EffectSummary}()  # MethodInstance => summary
const _lock = ReentrantLock()

# -----------------------------------------------------------------------------
# Utilities: types, handles, tracking
# -----------------------------------------------------------------------------

"Is `T` considered a \"tracked\" mutable reference for borrow checking?"
function is_tracked_type(@nospecialize T)::Bool
    seen = Base.IdSet{Any}()

    function inner(@nospecialize(T))::Bool
        T === Union{} && return false
        T === Any && return true  # conservative
        if T isa Union
            return any(inner, Base.uniontypes(T))
        end
        T isa Type || return true  # conservative for non-Type lattice elements

        # Arrays and common reference carriers
        if T <: AbstractArray
            return true
        end
        if isdefined(Base, :RefValue) && (T <: Base.RefValue)
            return true
        end

        dt = Base.unwrap_unionall(T)
        if dt isa DataType
            # Mutable structs are tracked.
            Base.ismutabletype(dt) && return true

            # Immutable structs are tracked if they *carry* tracked values (like `struct B; a::A; end`).
            Base.isbitstype(dt) && return false
            if dt in seen
                return true
            end
            push!(seen, dt)
            return any(inner, fieldtypes(dt))
        end
        return true
    end

    return inner(T)
end

@inline _ssa_handle(nargs::Int, id::Int) = nargs + id
@inline _arg_handle(id::Int) = id

@inline function _handle_index(x, nargs::Int, track_arg::AbstractVector{Bool}, track_ssa::AbstractVector{Bool})
    if x isa Core.Argument
        n = x.n
        return (1 <= n <= length(track_arg) && track_arg[n]) ? _arg_handle(n) : 0
    elseif x isa Core.SSAValue
        i = x.id
        return (1 <= i <= length(track_ssa) && track_ssa[i]) ? _ssa_handle(nargs, i) : 0
    else
        return 0
    end
end

function _stmt_lineinfo(ir::CC.IRCode, idx::Int)
    try
        inst = ir[Core.SSAValue(idx)]
        return get(inst, :line, nothing)
    catch
        return nothing
    end
end

# -----------------------------------------------------------------------------
# Union-Find (disjoint set) for alias classes
# -----------------------------------------------------------------------------

mutable struct UnionFind
    parent::Vector{Int}
    rank::Vector{UInt8}
end

function UnionFind(n::Int)
    parent = collect(1:n)
    rank = fill(UInt8(0), n)
    return UnionFind(parent, rank)
end

@inline function _uf_find(uf::UnionFind, x::Int)
    p = uf.parent[x]
    if p == x
        return x
    end
    r = _uf_find(uf, p)
    uf.parent[x] = r
    return r
end

@inline function _uf_union!(uf::UnionFind, a::Int, b::Int)
    ((a == 0) || (b == 0) || (a == b)) && return
    ra = _uf_find(uf, a)
    rb = _uf_find(uf, b)
    ra == rb && return
    if uf.rank[ra] < uf.rank[rb]
        uf.parent[ra] = rb
    elseif uf.rank[ra] > uf.rank[rb]
        uf.parent[rb] = ra
    else
        uf.parent[rb] = ra
        uf.rank[ra] += 1
    end
    return
end

# -----------------------------------------------------------------------------
# IR helpers (calls, argument lists)
# -----------------------------------------------------------------------------

"Return (head, mi, raw_args) where raw_args[1] is function value. mi is nothing for :call."
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

"Try to resolve the callee function object for a call/invoke. Returns `nothing` if not a known constant."
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

"Return function name string if available, else \"\"."
function _callee_name_str(@nospecialize(f))
    try
        return String(Base.nameof(f))
    catch
        return ""
    end
end

# -----------------------------------------------------------------------------
# Effect summary inference
# -----------------------------------------------------------------------------

"""
Get an effect summary for a *call site*.

This returns effects in terms of positions in `raw_args` where:
- `raw_args[1]` is function value
- `raw_args[2]` is first argument, etc
"""
function _effects_for_call(stmt, ir::CC.IRCode, cfg::Config, track_arg, track_ssa, nargs::Int; depth::Int=0)::EffectSummary
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
    if head === :invoke && cfg.analyze_invokes && (mi !== nothing) && depth < cfg.max_summary_depth
        s = _summary_for_mi(mi, cfg; depth=depth+1)
        if s !== nothing
            return s
        end
    end

    # Heuristic convention for known constant callees.
    if f !== nothing
        nm = _callee_name_str(f)
        if cfg.assume_bang_mutates && endswith(nm, "!")
            return EffectSummary(writes=[2])
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
        return EffectSummary(consumes=consumes)
    else
        return EffectSummary()
    end
end

"Summarize a MethodInstance by analyzing its IRCode (conservative; cached)."
function _summary_for_mi(mi, cfg::Config; depth::Int)
    # Avoid summarizing Base/Core in this MVP: it's huge and unstable across versions.
    try
        if mi isa Core.MethodInstance
            m = mi.def
            if (m isa Method) && (m.module === Base || m.module === Core || m.module === Experimental)
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

"Conservatively summarize which formal args of `ir` are written/consumed by the method."
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
            CC.widenconst(get(inst, :type, Any))
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

    return EffectSummary(writes=writes, consumes=consumes)
end

# -----------------------------------------------------------------------------
# Alias-class construction
# -----------------------------------------------------------------------------

function _build_alias_classes!(uf::UnionFind, ir::CC.IRCode, cfg::Config, track_arg, track_ssa, nargs::Int; depth::Int=0)
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

# -----------------------------------------------------------------------------
# Liveness analysis (NLL-style) on tracked handles
# -----------------------------------------------------------------------------

"Collect used handles of a statement (excluding phi-edge semantics; caller handles phi specially)."
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

# -----------------------------------------------------------------------------
# Main checker
# -----------------------------------------------------------------------------

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
            CC.widenconst(get(inst, :type, Any))
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
            uses = (stmt isa Core.PhiNode || stmt isa Core.PhiCNode) ? BitSet() : _used_handles(stmt, nargs, track_arg, track_ssa)
            live_during = BitSet(live)
            union!(live_during, uses)

            # Perform checks.
            _check_stmt!(viols, ir, idx, stmt, uf, cfg, nargs, track_arg, track_ssa, live, live_during)

            # Update liveness for previous statement.
            if 1 <= idx <= length(track_ssa) && track_ssa[idx]
                delete!(live, _ssa_handle(nargs, idx))
            end
            union!(live, uses)
        end
    end

    return viols
end

function _check_stmt!(viols, ir::CC.IRCode, idx::Int, stmt, uf::UnionFind, cfg::Config,
                     nargs::Int, track_arg, track_ssa, live_after::BitSet, live_during::BitSet)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return

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

function _require_unique!(viols, ir::CC.IRCode, idx::Int, stmt, uf::UnionFind, hv::Int, live_during::BitSet; context::String)
    rv = _uf_find(uf, hv)
    for h2 in live_during
        h2 == hv && continue
        if _uf_find(uf, h2) == rv
            li = _stmt_lineinfo(ir, idx)
            push!(viols, BorrowViolation(idx,
                "cannot perform $context: value is aliased by another live binding",
                li, stmt))
            return
        end
    end
end

function _require_not_used_later!(viols, ir::CC.IRCode, idx::Int, stmt, uf::UnionFind, hv::Int, live_after::BitSet)
    rv = _uf_find(uf, hv)
    for h2 in live_after
        if _uf_find(uf, h2) == rv
            li = _stmt_lineinfo(ir, idx)
            push!(viols, BorrowViolation(idx,
                "value escapes/consumed by unknown call; it (or an alias) is used later",
                li, stmt))
            return
        end
    end
end

# -----------------------------------------------------------------------------
# Public API: checking a specialization and macro entry
# -----------------------------------------------------------------------------

"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
function check_signature(tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world::UInt=Base.get_world_counter())
    codes = Base.code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
    viols = BorrowViolation[]
    for entry in codes
        ir = entry.first
        ir isa CC.IRCode || continue
        append!(viols, check_ir(ir, cfg))
    end
    isempty(viols) || throw(BorrowCheckError(tt, viols))
    return true
end

"""
Internal entry inserted by the macro at the beginning of checked functions.

This memoizes successful checks per-method-specialization and re-checks when the world age changes.
"""
function __bc_assert_safe__(tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG)
    world = Base.get_world_counter()
    lock(_lock) do
        w = get(_checked_cache, tt, UInt(0))
        if w == world
            return nothing
        end
    end
    check_signature(tt; cfg=cfg, world=world)
    lock(_lock) do
        _checked_cache[tt] = world
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Macro: @borrow_checker
# -----------------------------------------------------------------------------

# Extract the call expression from a signature (handles where/return-type annotations).
function _sig_call(sig)
    while sig isa Expr && sig.head === :where
        sig = sig.args[1]
    end
    if sig isa Expr && sig.head === :(::)
        sig = sig.args[1]
    end
    return sig
end

function _fval_expr_from_sigcall(call)
    fhead = call.args[1]
    if fhead isa Symbol
        return fhead
    elseif fhead isa Expr && fhead.head === :(::)
        # (f::T)(args...) form
        return fhead.args[1]
    else
        return fhead
    end
end

function _argref_expr(arg)
    if arg isa Symbol
        return arg
    elseif arg isa Expr && arg.head === :(::)
        return arg.args[1]
    elseif arg isa Expr && arg.head === :kw
        return arg.args[1]
    elseif arg isa Expr && arg.head === :...
        inner = _argref_expr(arg.args[1])
        return Expr(:..., inner)
    elseif arg isa Expr && arg.head === :parameters
        # keyword argument container; ignore for type tuple construction
        return nothing
    else
        return arg
    end
end

function _tt_expr_from_signature(sig)
    call = _sig_call(sig)
    call isa Expr && call.head === :call || error("@borrow_checker currently supports standard function signatures")
    fval = _fval_expr_from_sigcall(call)
    argrefs = Any[]
    for a in call.args[2:end]
        r = _argref_expr(a)
        r === nothing && continue
        push!(argrefs, r)
    end
    tup = Expr(:tuple, fval, argrefs...)
    return :(typeof($tup))
end

function _is_method_definition_lhs(lhs)
    lhs isa Expr || return false
    # Local method definition forms appear as assignment with a call-like LHS.
    return lhs.head === :call || lhs.head === :where || lhs.head === :(::)
end

function _instrument_assignments(ex)
    ex isa Expr || return ex

    # Don't instrument inside nested function definitions or quoted code.
    if ex.head === :function || ex.head === :(->) || ex.head === :quote || ex.head === :inert
        return ex
    end

    if ex.head === :(=) && length(ex.args) == 2
        lhs, rhs = ex.args
        if _is_method_definition_lhs(lhs)
            return ex
        end
        lhs2 = _instrument_assignments(lhs)
        rhs2 = _instrument_assignments(rhs)
        return Expr(:(=), lhs2, :(BorrowChecker.Experimental.__bc_bind__($rhs2)))
    end

    # Recurse
    return Expr(ex.head, map(_instrument_assignments, ex.args)...)
end

function _prepend_check_stmt(sig, body)
    tt_expr = _tt_expr_from_signature(sig)
    check_stmt = :(BorrowChecker.Experimental.__bc_assert_safe__($tt_expr))

    body_block = (body isa Expr && body.head === :block) ? body : Expr(:block, body)
    new_body = Expr(:block, check_stmt, body_block.args...)
    return _instrument_assignments(new_body)
end

macro borrow_checker(ex)
    is_borrow_checker_enabled(__module__) || return esc(ex)

    # Function form
    if ex isa Expr && ex.head === :function
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body)
        return esc(Expr(:function, sig, inst_body))
    end

    # One-line method form: f(args...) = body
    if ex isa Expr && ex.head === :(=) && _is_method_definition_lhs(ex.args[1])
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body)
        return esc(Expr(:function, sig, inst_body))
    end

    # Block form: create a private thunk and run it (best-effort; captures are not checked precisely).
    fname = gensym(:__bc_block__)
    fdef = Expr(:function, Expr(:call, fname), Expr(:block, _instrument_assignments(ex)))
    call = Expr(:call, fname)
    return esc(Expr(:block, fdef, call))
end

__precompile__(false)
