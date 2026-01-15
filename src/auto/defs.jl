@inline function _optimize_until_norm(s::AbstractString)
    return replace(lowercase(String(s)), r"[^a-z0-9]+" => "")
end

@inline function _normalize_optimize_until(opt::String)
    if isdefined(CC, :ALL_PASS_NAMES)
        optn = _optimize_until_norm(opt)
        idx = findfirst(nm -> endswith(_optimize_until_norm(String(nm)), optn), CC.ALL_PASS_NAMES)
        idx === nothing && return opt
        return String(CC.ALL_PASS_NAMES[idx])
    end
    return opt
end
@inline _normalize_optimize_until(opt) = opt

function _default_optimize_until()
    isdefined(CC, :ALL_PASS_NAMES) && return _normalize_optimize_until("compact 1")
    return "compact 1"
end

Base.@kwdef struct Config
    "Which compiler pass to stop at when fetching IR (`Base.code_ircode_by_type`)."
    optimize_until::Union{String,Int,Nothing} = _default_optimize_until()

    "Max depth for recursive effect summarization."
    max_summary_depth::Int = 12

    "Recursively borrow-check callees (call graph) within this scope."
    scope::Symbol = :function

    "Root module used by `scope=:module`."
    root_module::Module = Main
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

const KNOWN_EFFECTS = Lockable(IdDict{Any,EffectSummary}())

@inline function _known_effects_get(@nospecialize(f))
    return @lock KNOWN_EFFECTS get(KNOWN_EFFECTS[], f, nothing)
end

@inline function _known_effects_has(@nospecialize(f))::Bool
    return @lock KNOWN_EFFECTS haskey(KNOWN_EFFECTS[], f)
end

function register_effects!(@nospecialize(f); writes=(), consumes=(), ret_aliases=())
    @lock KNOWN_EFFECTS begin
        dict = KNOWN_EFFECTS[]
        dict[f] = EffectSummary(;
            writes=collect(Int, writes),
            consumes=collect(Int, consumes),
            ret_aliases=collect(Int, ret_aliases),
        )
    end
    return f
end

const REGISTRY_INITED = Lockable(Ref{Bool}(false))

function _populate_registry!()
    _known_effects_has(__bc_bind__) || register_effects!(__bc_bind__; ret_aliases=(2,))
    # `@auto scope=...` builds a `Config` object at runtime for the prologue check.
    # This constructor is internal plumbing and should be treated as pure.
    _known_effects_has(Config) || register_effects!(Config; ret_aliases=())

    if isdefined(Auto, :__bc_assert_safe__)
        f = Auto.__bc_assert_safe__
        _known_effects_has(f) || register_effects!(f; ret_aliases=())
    end

    if isdefined(Base, :inferencebarrier)
        f = Base.inferencebarrier
        _known_effects_has(f) || register_effects!(f; ret_aliases=(2,))
    end

    # NOTE: For a Rust-like borrow checker, *storing* a tracked value into mutable memory
    # must be treated as an escape/move of that value.
    specs = [
        (Core, :tuple, (), (), ()),
        (Core, :apply_type, (), (), ()),
        (Core, :typeof, (), (), ()),
        (Core, :_typeof_captured_variable, (), (), ()),
        (Core, :Typeof, (), (), ()),
        (Core, :isa, (), (), ()),
        (Core, :has_free_typevars, (), (), ()),
        (Core, :InexactError, (), (), ()),
        (Core, :BoundsError, (), (), ()),
        (Core, :throw, (), (), ()),
        (Core, :(===), (), (), ()),
        (Core, :(!==), (), (), ()),
        (Core, :typeassert, (2,), (), ()),
        (Core, :getfield, (2,), (), ()),
        # setfield!(obj, field, val) mutates `obj` (arg2) and stores `val` (arg4).
        # Storing an owned value is treated as a move/escape (filtered by `is_owned_type`).
        (Core, :setfield!, (), (2,), (4,)),
        # Field "write" family. All mutate the receiver (arg2) and store a value argument.
        (Core, :swapfield!, (), (2,), (4,)),      # swapfield!(obj, field, val, ...)
        (Core, :modifyfield!, (), (2,), (5,)),    # modifyfield!(obj, field, op, val, ...)
        (Core, :replacefield!, (), (2,), (5,)),   # replacefield!(obj, field, expected, val, ...)
        (Core, :setfieldonce!, (), (2,), (4,)),   # setfieldonce!(obj, field, val, ...)

        # `memoryref*` family. These are used by Base array code. They exist in `Core`
        # on Julia 1.12+; some are also exported from `Base` as aliases of the same function.
        (Core, :memoryrefnew, (2,), (), ()),
        (Core, :memoryref, (2,), (), ()),
        (Core, :memoryrefoffset, (2,), (), ()),
        (Core, :memoryrefget, (), (), ()),
        (Core, :memoryrefset!, (), (2,), (3,)),
        (Core, :memoryrefswap!, (), (2,), (3,)),
        (Core, :memoryrefmodify!, (), (2,), (4,)),
        (Core, :memoryrefreplace!, (), (2,), (4,)),
        (Core, :memoryrefsetonce!, (), (2,), (3,)),
        (Core, :memorynew, (), (), ()),

        # Pointer intrinsics:
        # `pointerset(ptr, val, idx, align)` mutates memory through `ptr` and often
        # appears as an intrinsic (no reflectable IR), so register it explicitly.
        (Core.Intrinsics, :pointerset, (2,), (2,), ()),
    ]

    for (mod, nm, ret_aliases, writes, consumes) in specs
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        _known_effects_has(f) ||
            register_effects!(f; writes=writes, consumes=consumes, ret_aliases=ret_aliases)
    end

    return nothing
end

function _ensure_registry_initialized()
    @lock REGISTRY_INITED begin
        r = REGISTRY_INITED[]
        if !r[]
            _populate_registry!()
            r[] = true
        end
    end
    return nothing
end
