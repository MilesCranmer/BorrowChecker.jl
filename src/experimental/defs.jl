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
        return get(inst, :line, nothing)
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
