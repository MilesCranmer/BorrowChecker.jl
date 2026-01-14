"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
const _checked_cache = Lockable(IdDict{Any,UInt}())  # Type{Tuple...} => world
const _per_task_checked_cache = PerTaskCache{IdDict{Any,UInt}}()

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
        end
        isempty(viols) || throw(BorrowCheckError(tt, viols))
        return true
    end
end

Base.@noinline function __bc_assert_safe__(
    tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world=Base.get_world_counter()
)
    @nospecialize tt
    task_cache = _per_task_checked_cache[]

    # Fast path: per-task cache (no locking).
    if get(task_cache, tt, UInt(0)) == world
        return nothing
    end

    # Slow path: shared cache (locked).
    #     Lock spans the entire inference so we avoid repeated inference.
    Base.@lock _checked_cache begin
        if get(_checked_cache[], tt, UInt(0)) == world
            task_cache[tt] = world
            return nothing
        end

        check_signature(tt; cfg=cfg, world=world)

        _checked_cache[][tt] = world
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
    args = Expr(:tuple)
    for a in call.args[2:end]
        r = _argref_expr(a)
        r === nothing && continue
        push!(args.args, r)
    end
    return :(Tuple{$Core.Typeof($fval),map(Core.Typeof, $args)...})
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

function _prepend_check_stmt(sig, body)
    tt_expr = _tt_expr_from_signature(sig)
    assert_ref = GlobalRef(@__MODULE__, :_generated_assert_safe)
    check_stmt = Expr(:call, assert_ref, tt_expr)

    body_block = (body isa Expr && body.head === :block) ? body : Expr(:block, body)
    new_body = Expr(:block, check_stmt, body_block.args...)
    return _instrument_assignments(new_body)
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
macro auto(ex)
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

    return error("@auto must wrap a function/method definition")
end
