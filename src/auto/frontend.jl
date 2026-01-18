"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
const CheckedCacheSig = Tuple{String,Int,Symbol,Bool,Int}

@inline function _checked_cache_sig(cfg::Config)
    # Intentionally ignores `root_module`: we cache only based on the checking policy.
    return (
        cfg.optimize_until,
        cfg.max_summary_depth,
        cfg.scope,
        cfg.debug,
        cfg.debug_callee_depth,
    )::CheckedCacheSig
end

const CHECKED_CACHE = Lockable(IdDict{Any,Tuple{UInt,CheckedCacheSig}}()) # Type{Tuple...} => (world, sig)
const PER_TASK_CHECKED_CACHE = PerTaskCache{IdDict{Any,Tuple{UInt,CheckedCacheSig}}}()

# Marker for "currently being checked". Prevents infinite recursion when `scope`
# triggers re-entrant borrow-checking of the same specialization.
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

function _module_is_under(m::Module, root::Module)::Bool
    mm = m
    while true
        mm === root && return true
        parent = try
            Base.parentmodule(mm)
        catch
            return false
        end
        parent === mm && return false
        mm = parent
    end
end

function _scope_allows_module(m::Module, cfg::Config)::Bool
    # Never recursively borrow-check BorrowChecker itself.
    m === Auto && return false

    cfg.scope === :all && return true
    if cfg.scope === :none || cfg.scope === :function
        return false
    elseif cfg.scope === :module
        return m === cfg.root_module
    elseif cfg.scope === :user
        # "user" means: only recurse into user code (no Core/Base, including submodules).
        return !(_module_is_under(m, Base) || _module_is_under(m, Core))
    end
    throw(ArgumentError("unknown scope: $(cfg.scope)"))
end

function _scope_allows_tt(tt::Type{<:Tuple}, cfg::Config)::Bool
    m = _tt_module(tt)
    m === nothing && return false
    return _scope_allows_module(m, cfg)
end

function _callsite_method_module(i::Int, head, mi, ir::CC.IRCode)
    if head === :invoke && mi !== nothing
        try
            return getfield(getfield(mi, :def), :module)
        catch
        end
        return nothing
    end

    info = try
        ir[Core.SSAValue(i)][:info]
    catch
        nothing
    end
    try
        info === nothing && return nothing

        callinfo = if hasproperty(info, :call)
            getproperty(info, :call)
        else
            info
        end

        hasproperty(callinfo, :results) || return nothing
        lr = getproperty(callinfo, :results)
        hasproperty(lr, :matches) || return nothing
        matches = getproperty(lr, :matches)
        length(matches) == 1 || return nothing
        mm = matches[1]
        hasproperty(mm, :method) || return nothing
        meth = getproperty(mm, :method)
        hasproperty(meth, :module) || return nothing
        return getproperty(meth, :module)
    catch
        return nothing
    end
end

function _apply_iterate_inner_tt(raw_args, ir::CC.IRCode)
    length(raw_args) >= 3 || return nothing
    inner_f = try
        CC.singleton_type(_safe_argextype(raw_args[3], ir))
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
            _call_tt_from_raw_args(raw_args, ir, f)
        end
        tt === nothing && continue
        tt isa Type{<:Tuple} || continue
        m = _callsite_method_module(i, head, mi, ir)
        if m === nothing
            m = _tt_module(tt)
            m === nothing && continue
        end
        _scope_allows_module(m, cfg) || continue

        try
            __bc_assert_safe__(tt; cfg=cfg, world=world)
        catch e
            # `scope=:all` is intentionally aggressive and compiler-dependent. Base/Core IR
            # routinely uses low-level memory primitives that can trigger spurious violations.
            # Treat these as non-fatal so `scope=:all` remains usable for user-code debugging.
            if cfg.scope === :all &&
                (e isa BorrowCheckError) &&
                (_module_is_under(m, Base) || _module_is_under(m, Core))
                continue
            end
            rethrow()
        end
    end

    return nothing
end

function check_signature(
    tt::Type{<:Tuple}; cfg::Config=Config(), world::UInt=Base.get_world_counter()
)
    @nospecialize tt
    _ensure_registry_initialized()
    return _with_reflection_ctx(world) do
        summary_snapshot = cfg.debug ? _auto_debug_summary_keys(UInt(world), cfg) : nothing
        debug_ok = true
        debug_violations = BorrowViolation[]
        debug_err = nothing
        debug_bt = nothing

        try
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
        catch e
            debug_ok = false
            debug_err = e
            debug_bt = catch_backtrace()
            if e isa BorrowCheckError
                append!(debug_violations, e.violations)
            end
            rethrow()
        finally
            if cfg.debug
                try
                    _auto_debug_emit_check!(
                        tt,
                        cfg,
                        UInt(world),
                        summary_snapshot,
                        debug_ok,
                        debug_violations,
                        debug_err,
                        debug_bt,
                    )
                catch
                end
            end
        end
    end
end

Base.@noinline function __bc_assert_safe__(
    tt::Type{<:Tuple}; cfg::Config=Config(), world::UInt=Base.get_world_counter()
)
    @nospecialize tt
    task_cache = PER_TASK_CHECKED_CACHE[]
    sig = _checked_cache_sig(cfg)

    # Fast path: per-task cache (no locking).
    state = get(task_cache, tt, nothing)
    if state !== nothing
        world0, sig0 = state
        if world0 == world && sig0 == sig
            return nothing
        end
    end

    # Slow path: shared cache (locked).
    #     Lock spans the entire inference so we avoid repeated inference.
    Base.@lock CHECKED_CACHE begin
        dict = CHECKED_CACHE[]
        state = get(dict, tt, nothing)
        if state !== nothing
            world0, sig0 = state
            if world0 == world && sig0 == sig
                task_cache[tt] = state
                return nothing
            end
            if world0 == BC_INPROGRESS_WORLD && sig0 == sig
                return nothing
            end
        end

        dict[tt] = (BC_INPROGRESS_WORLD, sig)
        try
            check_signature(tt; cfg=cfg, world=world)
        catch
            delete!(dict, tt)
            rethrow()
        end
        new_state = (world, sig)
        dict[tt] = new_state
        task_cache[tt] = new_state
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
        return _argref_expr(arg.args[1])
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

function _tt_expr_from_signature(sig, cfg_tag)
    call = _sig_call(sig)
    call isa Expr && call.head === :call ||
        error("@auto currently supports standard function signatures")
    fval = _fval_expr_from_sigcall(call)

    params = Any[cfg_tag, :(Core.Typeof($fval))]
    for a in call.args[2:end]
        # Anonymous typed arguments appear as `(::T)` or `(::T=default)` in the AST.
        # These do not have a runtime value binding, so we cannot take `Core.Typeof` of them.
        if a isa Expr && a.head === :kw
            a = a.args[1]
        end

        if a isa Expr && a.head === :(::) && length(a.args) == 1
            push!(params, a.args[1])
            continue
        end

        r = _argref_expr(a)
        r === nothing && continue

        if r isa Expr && r.head === :...
            t = Expr(:tuple, r)
            push!(params, Expr(:..., :(map(Core.Typeof, $t))))
        else
            push!(params, :(Core.Typeof($r)))
        end
    end

    return Expr(:curly, :Tuple, params...)
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

function _instrument_lambda(ex::Expr, cfg_tag)
    @assert ex.head === :(->)
    args_expr = ex.args[1]
    body = ex.args[2]

    fname = gensym(:__bc_lambda__)
    arglist = _lambda_arglist(args_expr)
    sig = Expr(:call, fname, arglist...)
    inst_body = _prepend_check_stmt(sig, body, cfg_tag)
    fdef = Expr(:function, sig, inst_body)
    return Expr(:block, fdef, fname)
end

function _instrument_assignments(ex, cfg_tag)
    ex isa Expr || return ex

    if ex.head === :quote || ex.head === :inert
        return ex
    end

    if ex.head === :function
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body, cfg_tag)
        return Expr(:function, sig, inst_body)
    end

    if ex.head === :(->)
        return _instrument_lambda(ex, cfg_tag)
    end

    if ex.head === :(=) && length(ex.args) == 2
        lhs, rhs = ex.args
        if _is_method_definition_lhs(lhs)
            sig = lhs
            body = rhs
            inst_body = _prepend_check_stmt(sig, body, cfg_tag)
            return Expr(:function, sig, inst_body)
        end
        lhs2 = _instrument_assignments(lhs, cfg_tag)
        rhs2 = _instrument_assignments(rhs, cfg_tag)

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
    return Expr(ex.head, map(a -> _instrument_assignments(a, cfg_tag), ex.args)...)
end

function _prepend_check_stmt(sig, body, cfg_tag, debug::Bool=false)
    tt_expr = _tt_expr_from_signature(sig, cfg_tag)
    assert_ref = GlobalRef(@__MODULE__, :_generated_assert_safe)
    check_stmt = Expr(:call, assert_ref, tt_expr)

    body_block = (body isa Expr && body.head === :block) ? body : Expr(:block, body)
    debug_warn_stmt = if debug
        path_ref = GlobalRef(@__MODULE__, :_auto_debug_path)
        Expr(:call, path_ref, true)
    else
        nothing
    end
    new_body = if debug_warn_stmt === nothing
        Expr(:block, check_stmt, body_block.args...)
    else
        Expr(:block, debug_warn_stmt, check_stmt, body_block.args...)
    end
    return _instrument_assignments(new_body, cfg_tag)
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

Returns a fully-specified `Config`.
"""
function parse_config(options, calling_module)::Config
    cfg0 = Config()
    scope = cfg0.scope
    max_summary_depth = cfg0.max_summary_depth
    optimize_until = cfg0.optimize_until
    debug = cfg0.debug
    debug_callee_depth = cfg0.debug_callee_depth
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
                optimize_until = _parse_cfg_value(v, calling_module)::String
                continue
            elseif k === :debug
                debug = _parse_cfg_value(v, calling_module)::Bool
                continue
            elseif k === :debug_callee_depth
                debug_callee_depth = _parse_cfg_value(v, calling_module)::Int
                continue
            end
        end
        error(
            "@auto only supports `scope=...`, `max_summary_depth=...`, `optimize_until=...`, `debug=...`, `debug_callee_depth=...`; got: $option",
        )
    end

    scope ∈ (:none, :function, :module, :user, :all) || error(
        "invalid `scope` for @auto: $scope (expected :none, :function, :module, :user, or :all)",
    )

    root_module = (scope === :module) ? calling_module : cfg0.root_module
    debug_callee_depth >= 0 ||
        error("`debug_callee_depth` must be >= 0; got: $debug_callee_depth")
    return Config(
        optimize_until, max_summary_depth, scope, root_module, debug, debug_callee_depth
    )
end

function _auto(args...; calling_module, source_info=nothing)
    _ = source_info

    ex = args[end]
    is_borrow_checker_enabled(calling_module) || return ex

    raw_options = args[begin:(end - 1)]
    cfg = parse_config(raw_options, calling_module)
    if cfg.scope === :none
        return ex
    end

    cfg_tag = let
        tag_ref = GlobalRef(@__MODULE__, :GeneratedCfgTag)
        Expr(
            :curly,
            tag_ref,
            QuoteNode(cfg.scope),
            cfg.max_summary_depth,
            QuoteNode(Symbol(cfg.optimize_until)),
            cfg.debug,
            cfg.debug_callee_depth,
        )
    end

    # Function form
    if ex isa Expr && ex.head === :function
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body, cfg_tag, cfg.debug)
        return Expr(:function, sig, inst_body)
    end

    # One-line method form: f(args...) = body
    if ex isa Expr && ex.head === :(=) && _is_method_definition_lhs(ex.args[1])
        sig = ex.args[1]
        body = ex.args[2]
        inst_body = _prepend_check_stmt(sig, body, cfg_tag, cfg.debug)
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

## Options

Options are parsed by the macro and compiled into a `BorrowChecker.Auto.Config` (and are
part of the checked-cache key).

- `scope` (default: `:function`): controls whether the checker recursively borrow-checks
  callees (call-graph traversal).
  - `:none`: disable `@auto` entirely (no IR borrow-checking; returns the original definition).
  - `:function`: check only the annotated method.
  - `:module`: recursively check callees whose defining module matches the module where `@auto` is used.
  - `:user`: recursively check callees, but ignore `Core` and `Base` (including their submodules).
  - `:all`: recursively check callees across all modules (very aggressive).
- `max_summary_depth` (default: `12`): limits recursive effect summarization depth used
  when the checker cannot directly resolve effects.
- `debug` (default: `false`): enable best-effort debug logging to a JSONL file
  (path controlled by `BORROWCHECKER_AUTO_DEBUG_PATH`).
- `debug_callee_depth` (default: `2`): when `debug=true`, also dump IR for summary-recursion
  entries up to this depth (0 = only the entrypoint specialization).

Examples:

```julia
BorrowChecker.@auto scope=:module function f(x)
    g(x)
end

BorrowChecker.@auto max_summary_depth=4 optimize_until="compact 1" function h(x)
    g(x)
end
```

# Extended help

### `optimize_until`

`optimize_until` (default: `BorrowChecker.Auto.DEFAULT_CONFIG.optimize_until`) controls
which compiler pass to stop at when fetching IR via `Base.code_ircode_by_type`.

Pass names vary across Julia versions; `@auto` tries to normalize common spellings like
`"compact 1"` / `"compact_1"` when possible.

!!! warning
    This macro is highly experimental and compiler-dependent. There are likely bugs and
    false positives. It is intended for development and testing, and does not guarantee
    memory safety.
"""
macro auto(args...)
    return esc(_auto(args...; calling_module=__module__, source_info=__source__))
end
