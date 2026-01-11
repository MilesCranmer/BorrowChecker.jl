function _default_optimize_until()
    if isdefined(CC, :ALL_PASS_NAMES)
        # Prefer a stage before inlining but after slot2reg.
        # Keeping IR pre-inlining helps avoid optimizer rewrite artifacts
        # (e.g. copy-prop/return rewriting) that are unrelated to source-level
        # bindings, while still giving us a stable CFG.
        for nm in CC.ALL_PASS_NAMES
            s = lowercase(String(nm))
            if any(occursin(s), ("compact_1", "compact 1", "compact1", "slot2reg"))
                return nm
            end
        end
        return nothing
    end

    # Julia < 1.13 does not expose `Core.Compiler.ALL_PASS_NAMES`, but
    # `Base.code_ircode_by_type(...; optimize_until="compact 1")` is supported
    # and stops right before inlining on the 1.12 series.
    return "compact 1"
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
    If true, attempt to infer effects for `:invoke` calls by recursively summarizing
    the callee's `IRCode` (with recursion bounded by `max_summary_depth`).
    """
    analyze_invokes::Bool = true

    "Max depth for recursive effect summarization."
    max_summary_depth::Int = 12
end

const DEFAULT_CONFIG = Config()

@inline __bc_bind__(x) =
    isdefined(Base, :inferencebarrier) ? (Base.inferencebarrier(x)::typeof(x)) : x

struct EffectSummary
    # Indices are in the *raw call argument list* used by the SSA form:
    # raw_args[1] is the function value, raw_args[2] is the first user argument, etc.
    writes::BitSet    # arguments that may be mutated during the call
    consumes::BitSet  # arguments that may escape/need to be treated as consumed
    ret_aliases::BitSet  # arguments that the return value may alias
end
function EffectSummary(; writes=Int[], consumes=Int[], ret_aliases=Int[])
    return EffectSummary(BitSet(writes), BitSet(consumes), BitSet(ret_aliases))
end

const _known_effects = Lockable(IdDict{Any,EffectSummary}())

"""
Return-aliasing style for calls that return a *tracked* value.

* `:none`  -> assume return is fresh wrt arguments
* `:arg1`  -> return aliases the first user argument (raw_args[2])
* `:all`   -> return may alias any tracked argument (conservative default)
"""
const _ret_alias = Lockable(IdDict{Any,Symbol}())

@inline function _known_effects_get(@nospecialize(f))
    return @lock _known_effects get(_known_effects[], f, nothing)
end

@inline function _known_effects_has(@nospecialize(f))::Bool
    return @lock _known_effects haskey(_known_effects[], f)
end

@inline function _ret_alias_get(@nospecialize(f))
    return @lock _ret_alias get(_ret_alias[], f, nothing)
end

@inline function _ret_alias_has(@nospecialize(f))::Bool
    return @lock _ret_alias haskey(_ret_alias[], f)
end

function register_effects!(@nospecialize(f); writes=(), consumes=())
    @lock _known_effects begin
        _known_effects[][f] = EffectSummary(;
            writes=collect(Int, writes), consumes=collect(Int, consumes)
        )
    end
    return f
end

function register_return_alias!(@nospecialize(f), style::Symbol)
    @assert style in (:none, :arg1, :all)
    @lock _ret_alias begin
        _ret_alias[][f] = style
    end
    return f
end

const _registry_inited = Lockable(Ref{Bool}(false))

@inline function _maybe_register_effects!(@nospecialize(f); writes=(), consumes=())
    _known_effects_has(f) || register_effects!(f; writes=writes, consumes=consumes)
    return nothing
end

@inline function _maybe_register_ret_alias!(@nospecialize(f), ret_alias::Symbol)
    _ret_alias_has(f) || register_return_alias!(f, ret_alias)
    return nothing
end

@inline function _maybe_register_effects_and_alias!(
    @nospecialize(f), ret_alias::Symbol; writes=(), consumes=()
)
    _maybe_register_effects!(f; writes=writes, consumes=consumes)
    _maybe_register_ret_alias!(f, ret_alias)
    return nothing
end

function _populate_registry!()
    _maybe_register_effects_and_alias!(__bc_bind__, :arg1)

    if isdefined(Experimental, :__bc_assert_safe__)
        f = Experimental.__bc_assert_safe__
        _maybe_register_effects_and_alias!(f, :none)
    end

    if isdefined(Base, :inferencebarrier)
        f = Base.inferencebarrier
        _maybe_register_effects_and_alias!(f, :arg1)
    end

    # NOTE: For a Rust-like borrow checker, *storing* a tracked value into mutable memory
    # must be treated as an escape/move of that value.
    specs = [
        (Core, :tuple, :none, (), ()),
        (Core, :apply_type, :none, (), ()),
        (Core, :typeof, :none, (), ()),
        (Core, :_typeof_captured_variable, :none, (), ()),
        (Core, :(===), :none, (), ()),
        (Core, :(!==), :none, (), ()),
        (Core, :typeassert, :arg1, (), ()),
        (Core, :getfield, :arg1, (), ()),
        # setfield!(obj, field, val) mutates `obj` (arg2) and stores `val` (arg4).
        # Storing an owned value is treated as a move/escape (filtered by `is_owned_type`).
        (Core, :setfield!, :none, (2,), (4,)),
        # Field "write" family. All mutate the receiver (arg2) and store a value argument.
        (Core, :swapfield!, :none, (2,), (4,)),      # swapfield!(obj, field, val, ...)
        (Core, :modifyfield!, :none, (2,), (5,)),    # modifyfield!(obj, field, op, val, ...)
        (Core, :replacefield!, :none, (2,), (5,)),   # replacefield!(obj, field, expected, val, ...)
        (Core, :setfieldonce!, :none, (2,), (4,)),   # setfieldonce!(obj, field, val, ...)

        # `memoryref*` family. These are used by Base array code. They exist in `Core`
        # on Julia 1.12+; some are also exported from `Base` as aliases of the same function.
        (Core, :memoryrefnew, :arg1, (), ()),
        (Core, :memoryref, :arg1, (), ()),
        (Core, :memoryrefoffset, :arg1, (), ()),
        (Core, :memoryrefget, :none, (), ()),
        (Core, :memoryrefset!, :none, (2,), (3,)),
        (Core, :memoryrefswap!, :none, (2,), (3,)),
        (Core, :memoryrefmodify!, :none, (2,), (4,)),
        (Core, :memoryrefreplace!, :none, (2,), (4,)),
        (Core, :memoryrefsetonce!, :none, (2,), (3,)),
    ]

    for (mod, nm, ret_alias, writes, consumes) in specs
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        _maybe_register_effects_and_alias!(f, ret_alias; writes=writes, consumes=consumes)
    end

    return nothing
end

function _ensure_registry_initialized()
    @lock _registry_inited begin
        r = _registry_inited[]
        if !r[]
            _populate_registry!()
            r[] = true
        end
    end
    return nothing
end
