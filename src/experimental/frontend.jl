"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
function check_signature(
    tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world::UInt=Base.get_world_counter()
)
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
        error("@borrow_checker currently supports standard function signatures")
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
    if ex.head === :function ||
        ex.head === :(->) ||
        ex.head === :quote ||
        ex.head === :inert
        return ex
    end

    if ex.head === :(=) && length(ex.args) == 2
        lhs, rhs = ex.args
        if _is_method_definition_lhs(lhs)
            return ex
        end
        lhs2 = _instrument_assignments(lhs)
        rhs2 = _instrument_assignments(rhs)
        bind_ref = GlobalRef(@__MODULE__, :__bc_bind__)
        return Expr(:(=), lhs2, Expr(:call, bind_ref, rhs2))
    end

    # Recurse
    return Expr(ex.head, map(_instrument_assignments, ex.args)...)
end

function _prepend_check_stmt(sig, body)
    tt_expr = _tt_expr_from_signature(sig)
    assert_ref = GlobalRef(@__MODULE__, :__bc_assert_safe__)
    check_stmt = Expr(:call, assert_ref, tt_expr)

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
