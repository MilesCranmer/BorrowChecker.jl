"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
const CHECKED_CACHE = Lockable(IdDict{Any,UInt}())  # Type{Tuple...} => world
const PER_TASK_CHECKED_CACHE = PerTaskCache{IdDict{Any,UInt}}()

const BC_INPROGRESS_WORLD = typemax(UInt)

function _tt_module(tt::Type{<:Tuple})
    try
        tt_u = Base.unwrap_unionall(tt)
        if tt_u isa DataType && !isempty(tt_u.parameters)
            fT = tt_u.parameters[1]
            dt = Base.unwrap_unionall(fT)
            if dt isa DataType
                m = dt.name.module
                if dt.name === Base.unwrap_unionall(Type).name && !isempty(dt.parameters)
                    targ = Base.unwrap_unionall(dt.parameters[1])
                    if targ isa DataType
                        m = targ.name.module
                    end
                end
                return m
            end
        end
    catch
    end
    return nothing
end

function _scope_allows_tt(tt::Type{<:Tuple}, cfg::Config)::Bool
    cfg.scope === :all && return true
    m = _tt_module(tt)
    m === nothing && return false
    m === Auto && return false
    if cfg.scope === :none || cfg.scope === :function
        return false
    elseif cfg.scope === :module
        return m === cfg.root_module
    elseif cfg.scope === :user
        # "user" means: don't recursively check Base, but allow Core + other modules.
        return (m !== Base)
    end
    throw(ArgumentError("unknown scope: $(cfg.scope)"))
end

function _apply_iterate_inner_tt(raw_args, ir::CC.IRCode)
    length(raw_args) >= 3 || return nothing
    inner_f = try
        CC.singleton_type(CC.argextype(raw_args[3], ir))
    catch
        nothing
    end
    inner_f === nothing && return nothing

    expanded_types = Any[typeof(inner_f)]
    for j in 4:length(raw_args)
        argj = raw_args[j]
        elems = _maybe_tuple_elements(argj, ir)
        if elems !== nothing
            for e in elems
                push!(expanded_types, _widenargtype_or_any(e, ir))
            end
            continue
        end

        Tj = _widenargtype_or_any(argj, ir)
        Tj === Tuple{} && continue
        dt = Base.unwrap_unionall(Tj)
        if dt isa DataType && dt.name === Tuple.name
            params = dt.parameters
            has_vararg = any(p -> p isa Core.TypeofVararg, params)
            if !has_vararg
                for te in params
                    te2 = Base.unwrap_unionall(te)
                    push!(expanded_types, (te2 isa Type) ? te2 : Any)
                end
                continue
            end
        end

        push!(expanded_types, Tj)
    end

    try
        return Core.apply_type(Tuple, expanded_types...)
    catch
        return nothing
    end
end

function _check_ir_callees!(ir::CC.IRCode, cfg::Config, world::UInt)
    (cfg.scope === :none || cfg.scope === :function) && return nothing

    nstmts = length(ir.stmts)
    for i in 1:nstmts
        stmt = ir[Core.SSAValue(i)][:stmt]
        head, mi, raw_args = _call_parts(stmt)
        raw_args === nothing && continue

        f = _resolve_callee(stmt, ir)
        f === __bc_bind__ && continue
        f === __bc_assert_safe__ && continue

        tt = if f === Core._apply_iterate
            _apply_iterate_inner_tt(raw_args, ir)
        elseif f === Core.kwcall
            _kwcall_tt_from_raw_args(raw_args, ir)
        elseif head === :invoke && mi !== nothing
            try
                mi.specTypes
            catch
                nothing
            end
        else
            _call_tt_from_raw_args(raw_args, ir)
        end
        tt === nothing && continue
        tt isa Type{<:Tuple} || continue
        _scope_allows_tt(tt, cfg) || continue

        __bc_assert_safe__(tt; cfg=cfg, world=world)
    end

    return nothing
end

function check_signature(
    tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world::UInt=Base.get_world_counter()
)
    _ensure_registry_initialized()
    return _with_reflection_ctx(world) do
        codes = _code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        viols = BorrowViolation[]
        for entry in codes
            ir = entry.first
            ir isa CC.IRCode || continue
            append!(viols, check_ir(ir, cfg))
            _check_ir_callees!(ir, cfg, world)
        end
        isempty(viols) || throw(BorrowCheckError(tt, viols))
        return true
    end
end

Base.@noinline function __bc_assert_safe__(
    tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world::UInt=Base.get_world_counter()
)
    @nospecialize tt
    task_cache = PER_TASK_CHECKED_CACHE[]

    # Fast path: per-task cache (no locking).
    if get(task_cache, tt, UInt(0)) == world
        return nothing
    end

    # Slow path: shared cache (locked).
    #     Lock spans the entire inference so we avoid repeated inference.
    Base.@lock CHECKED_CACHE begin
        state = get(CHECKED_CACHE[], tt, UInt(0))
        if state == world
            task_cache[tt] = world
            return nothing
        end
        if state == BC_INPROGRESS_WORLD
            return nothing
        end

        CHECKED_CACHE[][tt] = BC_INPROGRESS_WORLD
        try
            check_signature(tt; cfg=cfg, world=world)
        catch
            delete!(CHECKED_CACHE[], tt)
            rethrow()
        end
        CHECKED_CACHE[][tt] = world
        task_cache[tt] = world
        return nothing
    end
end

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
    call isa Expr && call.head === :call ||
        error("@auto currently supports standard function signatures")
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
    # Be careful not to treat typed variable assignments like `x::T = rhs` as a
    # method definition.
    call = lhs
    while call isa Expr && call.head === :where
        call = call.args[1]
    end
    if call isa Expr && call.head === :(::)
        call = call.args[1]
    end
    return call isa Expr && call.head === :call
end

function _lambda_arglist(args_expr)
    if args_expr isa Expr && args_expr.head === :tuple
        return Any[args_expr.args...]
    elseif args_expr === nothing
        return Any[]
    else
        return Any[args_expr]
    end
end

function _instrument_lambda(ex::Expr)
    @assert ex.head === :(->)
    args_expr = ex.args[1]
    body = ex.args[2]

    fname = gensym(:__bc_lambda__)
    arglist = _lambda_arglist(args_expr)
    sig = Expr(:call, fname, arglist...)
    inst_body = _prepend_check_stmt(sig, body)
    fdef = Expr(:function, sig, inst_body)
    return Expr(:block, fdef, fname)
end

function _instrument_assignments(ex)
    ex isa Expr || return ex

    if ex.head === :quote || ex.head === :inert
        return ex
    end

    if ex.head === :function
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body)
        return Expr(:function, sig, inst_body)
    end

    if ex.head === :(->)
        return _instrument_lambda(ex)
    end

    if ex.head === :(=) && length(ex.args) == 2
        lhs, rhs = ex.args
        if _is_method_definition_lhs(lhs)
            sig = lhs
            body = rhs
            inst_body = _prepend_check_stmt(sig, body)
            return Expr(:function, sig, inst_body)
        end
        lhs2 = _instrument_assignments(lhs)
        rhs2 = _instrument_assignments(rhs)

        # If the RHS is an instrumented lambda block, don't wrap it in `__bc_bind__`.
        # Wrapping forces the value to `Any` and breaks call resolution, which makes
        # `f(x)` look like an unknown call that consumes tracked arguments.
        if rhs2 isa Expr && rhs2.head === :block && length(rhs2.args) >= 2
            last = rhs2.args[end]
            if last isa Symbol && any(
                a -> (
                    a isa Expr &&
                    a.head === :function &&
                    a.args[1] isa Expr &&
                    a.args[1].head === :call &&
                    a.args[1].args[1] == last
                ),
                rhs2.args[1:(end - 1)],
            )
                return Expr(:(=), lhs2, rhs2)
            end
        end

        bind_ref = GlobalRef(@__MODULE__, :__bc_bind__)
        return Expr(:(=), lhs2, Expr(:call, bind_ref, rhs2))
    end

    # Recurse
    return Expr(ex.head, map(_instrument_assignments, ex.args)...)
end

function _prepend_check_stmt(sig, body; cfg_expr=nothing)
    tt_expr = _tt_expr_from_signature(sig)
    assert_ref = GlobalRef(@__MODULE__, :__bc_assert_safe__)
    check_stmt = if cfg_expr === nothing
        Expr(:call, assert_ref, tt_expr)
    else
        Expr(:call, assert_ref, Expr(:parameters, Expr(:kw, :cfg, cfg_expr)), tt_expr)
    end

    body_block = (body isa Expr && body.head === :block) ? body : Expr(:block, body)
    new_body = Expr(:block, check_stmt, body_block.args...)
    return _instrument_assignments(new_body)
end

function _parse_cfg_value(x, calling_module)
    if x isa QuoteNode
        return x.value
    elseif x isa Expr
        return Core.eval(calling_module, x)
    else
        return x
    end
end

"""
Parse `@auto` macro options into `Config` field overrides.

Returns a named tuple with `nothing` meaning "use default":
`(; scope, max_summary_depth, optimize_until)`.
"""
function parse_config_overrides(options, calling_module)
    scope = nothing
    max_summary_depth = nothing
    optimize_until = nothing

    for option in options
        if option isa Expr &&
            length(option.args) == 2 &&
            (option.head === :(=) || option.head === :kw)
            k = option.args[1]
            v = option.args[2]
            if k === :scope
                scope = _parse_cfg_value(v, calling_module)::Symbol
                continue
            elseif k === :max_summary_depth
                max_summary_depth = _parse_cfg_value(v, calling_module)::Int
                continue
            elseif k === :optimize_until
                optimize_until =
                    _parse_cfg_value(v, calling_module)::Union{String,Int,Nothing}
                continue
            end
        end
        error(
            "@auto only supports `scope=...`, `max_summary_depth=...`, `optimize_until=...`; got: $option",
        )
    end

    return (; scope, max_summary_depth, optimize_until)
end

function _auto(args...; calling_module, source_info=nothing)
    _ = source_info

    ex = args[end]
    is_borrow_checker_enabled(calling_module) || return ex

    raw_options = args[begin:(end - 1)]
    overrides = parse_config_overrides(raw_options, calling_module)

    if overrides.scope === :none
        return ex
    end

    cfg_expr = if isempty(raw_options)
        nothing
    else
        cfg_ref = GlobalRef(@__MODULE__, :Config)
        # Avoid keyword construction here: it lowers through `Core.kwcall`, and when
        # `scope` recursion includes Core we end up recursively checking `kwcall`'s
        # plumbing instead of user code.
        default_ref = GlobalRef(@__MODULE__, :DEFAULT_CONFIG)

        scope = overrides.scope === nothing ? :function : (overrides.scope::Symbol)
        scope ∈ (:function, :module, :user, :all) || error(
            "invalid `scope` for @auto: $scope (expected :none, :function, :module, :user, or :all)",
        )
        msd = overrides.max_summary_depth
        opt = overrides.optimize_until

        opt_expr = opt === nothing ? :($default_ref.optimize_until) : opt
        msd_expr = msd === nothing ? :($default_ref.max_summary_depth) : msd
        scope_expr = QuoteNode(scope)
        root_expr =
            scope === :module ? QuoteNode(calling_module) : :($default_ref.root_module)

        :($cfg_ref($opt_expr, $msd_expr, $scope_expr, $root_expr))
    end

    # Function form
    if ex isa Expr && ex.head === :function
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body; cfg_expr=cfg_expr)
        return Expr(:function, sig, inst_body)
    end

    # One-line method form: f(args...) = body
    if ex isa Expr && ex.head === :(=) && _is_method_definition_lhs(ex.args[1])
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body; cfg_expr=cfg_expr)
        return Expr(:function, sig, inst_body)
    end

    return error("@auto must wrap a function/method definition")
end

"""
Automatically borrow-check a function (best-effort).

`BorrowChecker.@auto` is a *drop-in tripwire* for existing code:

- **Aliasing violations**: mutating a value while another live binding may observe that mutation.
- **Escapes / “moves”**: storing a mutable value somewhere that outlives the current scope
  (e.g. a global cache / a field / a container), then continuing to reference it locally.

On function entry, it checks the current specialization and caches the result so future
calls are fast. On failure it throws `BorrowCheckError` with best-effort source context.

!!! warning
    This macro is highly experimental and compiler-dependent. There are likely bugs and
    false positives. It is intended for development and testing, and does not guarantee
    memory safety.
"""
macro auto(args...)
    return esc(_auto(args...; calling_module=__module__, source_info=__source__))
end
