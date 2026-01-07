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
            if occursin("compact_1", s) ||
                occursin("compact 1", s) ||
                occursin("compact1", s)
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

@inline __bc_bind__(x) = x

struct EffectSummary
    # Indices are in the *raw call argument list* used by the SSA form:
    # raw_args[1] is the function value, raw_args[2] is the first user argument, etc.
    writes::BitSet    # arguments that may be mutated during the call
    consumes::BitSet  # arguments that may escape/need to be treated as consumed
end
function EffectSummary(; writes=Int[], consumes=Int[])
    return EffectSummary(BitSet(writes), BitSet(consumes))
end

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

function register_effects!(
    f; writes::AbstractVector{<:Integer}=Int[], consumes::AbstractVector{<:Integer}=Int[]
)
    _known_effects[f] = EffectSummary(;
        writes=collect(Int, writes), consumes=collect(Int, consumes)
    )
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
    for nm in (
        :push!,
        :pushfirst!,
        :pop!,
        :popfirst!,
        :append!,
        :empty!,
        :resize!,
        :sizehint!,
        :fill!,
        :sort!,
        :reverse!,
        :copyto!,
    )
        if isdefined(Base, nm)
            f = getfield(Base, nm)
            register_effects!(f; writes=[2])
            register_return_alias!(f, :arg1)
        end
    end
end

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

const _srcfile_cache = Dict{String,Vector{String}}()

@inline function _inst_get(@nospecialize(inst), sym::Symbol, default=nothing)
    try
        return inst[sym]
    catch
    end
    try
        return getproperty(inst, sym)
    catch
    end
    return default
end

function _normalize_lineinfo(ir::CC.IRCode, li)
    li === nothing && return nothing
    li isa Core.LineInfoNode && return li
    li isa LineNumberNode && return li

    if li isa Integer
        lii = Int(li)
        lii <= 0 && return nothing
        lt = try
            getproperty(ir, :linetable)
        catch
            nothing
        end
        if lt !== nothing && lii <= length(lt)
            linfo = lt[lii]
            return (linfo isa Core.LineInfoNode) ? linfo : nothing
        end
        return nothing
    end

    return nothing
end

@inline function _lineinfo_file_line(li::Core.LineInfoNode)
    file = try
        String(getproperty(li, :file))
    catch
        nothing
    end
    line = try
        Int(getproperty(li, :line))
    catch
        nothing
    end
    return file, line
end

@inline function _lineinfo_file_line(li::LineNumberNode)
    file = try
        String(getproperty(li, :file))
    catch
        nothing
    end
    line = try
        Int(getproperty(li, :line))
    catch
        nothing
    end
    return file, line
end

function _lineinfo_chain(li::Core.LineInfoNode)
    chain = Core.LineInfoNode[]
    cur = li
    while cur isa Core.LineInfoNode
        push!(chain, cur)
        cur = try
            getproperty(cur, :inlined_at)
        catch
            nothing
        end
    end
    return chain
end

function _read_file_lines(file::String)
    return get!(_srcfile_cache, file) do
        try
            readlines(file)
        catch
            String[]
        end
    end
end

function _recover_callee_from_tt(tt)
    try
        tt_u = Base.unwrap_unionall(tt)
        tt_u isa DataType || return (nothing, nothing)
        ps = tt_u.parameters
        isempty(ps) && return (nothing, nothing)
        fT = ps[1]
        Base.issingletontype(fT) || return (nothing, nothing)
        f = getfield(fT, :instance)
        argT = Tuple{ps[2:end]...}
        return (f, argT)
    catch
        return (nothing, nothing)
    end
end

function _print_source_context(io::IO, tt, li; context::Int=0)
    file, line = if li isa Core.LineInfoNode || li isa LineNumberNode
        _lineinfo_file_line(li)
    else
        return nothing
    end
    (file === nothing || line === nothing) && return nothing

    if li isa Core.LineInfoNode
        chain = _lineinfo_chain(li)
        for (k, c) in enumerate(chain)
            f, l = _lineinfo_file_line(c)
            (f === nothing || l === nothing) && continue
            if k == 1
                println(io, "      at ", f, ":", l)
            else
                println(io, "      inlined at ", f, ":", l)
            end
        end
    else
        println(io, "      at ", file, ":", line)
    end

    if isfile(file)
        lines = _read_file_lines(file)
        if 1 <= line <= length(lines)
            lo = max(1, line - context)
            hi = min(length(lines), line + context)
            for ln in lo:hi
                prefix = (ln == line) ? "      > " : "        "
                println(io, prefix, rpad(string(ln), 5), " ", lines[ln])
            end
            return nothing
        end
    end

    f, argT = _recover_callee_from_tt(tt)
    (f === nothing || argT === nothing) && return nothing

    cis = try
        Base.code_lowered(f, argT; debuginfo=:source)
    catch
        try
            Base.code_lowered(f, argT)
        catch
            Any[]
        end
    end
    isempty(cis) && return nothing

    filesym = Symbol(file)
    for ci in cis
        ci isa Core.CodeInfo || continue
        buf = Any[]

        # Older representation: LineNumberNode markers embedded in `ci.code`.
        collecting = false
        for st in ci.code
            if st isa LineNumberNode
                if collecting
                    break
                end
                collecting = (st.file == filesym && st.line == line)
                continue
            end
            collecting || continue
            push!(buf, st)
        end

        # Newer representation: locations via `codelocs` -> `linetable`.
        if isempty(buf)
            lt = try
                getproperty(ci, :linetable)
            catch
                nothing
            end
            locs = try
                getproperty(ci, :codelocs)
            catch
                nothing
            end
            if lt !== nothing && locs !== nothing
                first_idx = 0
                for i in 1:min(length(ci.code), length(locs))
                    loc = locs[i]
                    (loc isa Integer) || continue
                    lii = Int(loc)
                    (lii <= 0 || lii > length(lt)) && continue
                    li = lt[lii]
                    li isa Core.LineInfoNode || continue
                    (
                        String(getproperty(li, :file)) == file &&
                        Int(getproperty(li, :line)) == line
                    ) || continue
                    first_idx = i
                    break
                end
                if first_idx != 0
                    li0 = lt[Int(locs[first_idx])]
                    for j in first_idx:min(length(ci.code), length(locs))
                        loc = locs[j]
                        (loc isa Integer) || break
                        lii = Int(loc)
                        (lii <= 0 || lii > length(lt)) && break
                        lij = lt[lii]
                        lij == li0 || break
                        push!(buf, ci.code[j])
                    end
                end
            end
        end

        isempty(buf) && continue
        println(io, "      lowered:")
        for ex in buf
            s = try
                sprint(show, ex)
            catch
                ""
            end
            isempty(s) || println(io, "        ", s)
        end
        break
    end

    return nothing
end

function Base.showerror(io::IO, e::BorrowCheckError)
    println(io, "BorrowCheckError for specialization ", e.tt)
    for (k, v) in enumerate(e.violations)
        println(io)
        println(io, "  [", k, "] stmt#", v.idx, ": ", v.msg)
        if v.lineinfo !== nothing
            try
                _print_source_context(io, e.tt, v.lineinfo; context=0)
            catch
                println(io, "      ", v.lineinfo)
            end
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

const _checked_cache = IdDict{Any,UInt}()            # Type{Tuple...} => world
const _summary_cache = IdDict{Any,EffectSummary}()  # MethodInstance => summary
const _lock = ReentrantLock()

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
            Base.isconcretetype(dt) || return true

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

@inline function _handle_index(
    x, nargs::Int, track_arg::AbstractVector{Bool}, track_ssa::AbstractVector{Bool}
)
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
        li = _inst_get(inst, :line, nothing)
        return _normalize_lineinfo(ir, li)
    catch
        return nothing
    end
end

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
    ((a == 0) || (b == 0) || (a == b)) && return nothing
    ra = _uf_find(uf, a)
    rb = _uf_find(uf, b)
    ra == rb && return nothing
    if uf.rank[ra] < uf.rank[rb]
        uf.parent[ra] = rb
    elseif uf.rank[ra] > uf.rank[rb]
        uf.parent[rb] = ra
    else
        uf.parent[rb] = ra
        uf.rank[ra] += 1
    end
    return nothing
end
