"""
Run BorrowCheck on a concrete specialization `tt::Type{<:Tuple}`.

Returns `true` on success; throws `BorrowCheckError` on failure.
"""
# Type{Tuple...} => (world, cfg_key)
const _checked_cache = Lockable(IdDict{Any,Tuple{UInt,UInt}}())
const _checking_inprogress = Lockable(Base.IdSet{Any}())

@inline function _cfg_cache_key(cfg::Config)::UInt
    callee_roots_key = if cfg.callee_check_roots isa Symbol
        cfg.callee_check_roots
    else
        Tuple(cfg.callee_check_roots)
    end
    return UInt(
        hash((
            cfg.optimize_until,
            cfg.unknown_call_policy,
            cfg.analyze_invokes,
            cfg.max_summary_depth,
            callee_roots_key,
            cfg.max_callee_depth,
        )),
    )
end

const _DEFAULT_CFG_KEY = _cfg_cache_key(DEFAULT_CONFIG)

@inline function _method_module(tt::Type{<:Tuple}, world::UInt)::Union{Module,Nothing}
    mm = try
        Base._which(tt; world=world, raise=false)
    catch
        nothing
    end
    mm === nothing && return nothing
    return mm.method.module
end

@inline function _method_match(tt::Type{<:Tuple}, world::UInt)
    mm = try
        Base._which(tt; world=world, raise=false)
    catch
        nothing
    end
    return mm
end

function _package_root_module(m::Module)::Module
    cur = m
    while true
        parent = parentmodule(cur)
        parent === cur && return cur
        (parent === Main || parent === Base || parent === Core) && return cur
        cur = parent
    end
end

@inline function _callee_check_mode(cfg::Config, root_pkg::Module)
    roots = Module[]
    check_all = false

    spec = cfg.callee_check_roots
    if spec isa Symbol
        if spec === :none
            return roots, false
        elseif spec === :same_package
            push!(roots, root_pkg)
            return roots, false
        elseif spec === :all
            return roots, true
        else
            return roots, false
        end
    else
        append!(roots, spec)
        return roots, false
    end
end

@inline function _should_check_callee_module(callee_roots::Vector{Module}, check_all::Bool, mod::Module)::Bool
    (mod === Core || mod === Base || mod === Experimental) && return false
    check_all && return true
    isempty(callee_roots) && return false
    return _package_root_module(mod) in callee_roots
end

function _collect_callee_tts(ir::CC.IRCode)
    callees = Base.IdSet{Any}()
    nstmts = length(ir.stmts)

    for idx in 1:nstmts
        stmt = try
            ir[Core.SSAValue(idx)][:stmt]
        catch
            continue
        end
        head, mi, raw_args = _call_parts(stmt)
        raw_args === nothing && continue

        # Avoid recursively checking keyword-call plumbing. These methods are compiler-generated
        # and tend to be noisy/fragile under borrow checking (the call-site check already
        # handles aliasing through keyword values).
        f = _resolve_callee(stmt, ir)
        f === Core.kwcall && continue

        # Only recurse on 0-argument calls. This is the main unsoundness hole: if a call site has
        # no tracked values crossing the boundary, caller-side checks can't say anything.
        # (Checking every untracked call is too expensive.)
        length(raw_args) == 1 || continue
        callee_expr = raw_args[1]
        callee_expr isa Core.Argument && continue

        if head === :invoke && (mi isa Core.MethodInstance)
            push!(callees, mi.specTypes)
        elseif head === :call
            # If the callee isn't constant, skip; checking arbitrary function-typed SSA values
            # explodes quickly and doesn't address the "0-arg unknown call" hole we care about.
            f === nothing && continue
            tt = try
                _call_tt_from_raw_args(raw_args, ir)
            catch
                nothing
            end
            tt !== nothing && push!(callees, tt)
        end
    end

    return callees
end

function check_signature(tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG, world::UInt=Base.get_world_counter())
    @nospecialize tt

    cfg_key = (cfg === DEFAULT_CONFIG) ? _DEFAULT_CFG_KEY : _cfg_cache_key(cfg)

    cached = false
    Base.@lock _checked_cache begin
        stamp = get(_checked_cache[], tt, nothing)
        cached = (stamp !== nothing && stamp[1] == world && stamp[2] == cfg_key)
    end
    cached && return true

    _ensure_registry_initialized()

    mod = _method_module(tt, world)
    root_pkg = mod === nothing ? Main : _package_root_module(mod)
    callee_roots, check_all = _callee_check_mode(cfg, root_pkg)

    return _check_signature_recursive(
        tt;
        cfg=cfg,
        world=world,
        depth=0,
        callee_roots=callee_roots,
        check_all=check_all,
        cfg_key=cfg_key,
    )
end

function _check_signature_recursive(
    tt::Type{<:Tuple};
    cfg::Config,
    world::UInt,
    depth::Int,
    callee_roots::Vector{Module},
    check_all::Bool,
    cfg_key::UInt,
)
    @nospecialize tt

    cached = false
    Base.@lock _checked_cache begin
        stamp = get(_checked_cache[], tt, nothing)
        cached = (stamp !== nothing && stamp[1] == world && stamp[2] == cfg_key)
    end
    cached && return true

    already = false
    Base.@lock _checking_inprogress begin
        already = (tt in _checking_inprogress[])
        already || push!(_checking_inprogress[], tt)
    end
    already && return true

    try
        opt_until = (depth == 0) ? cfg.optimize_until : "slot2reg"
        codes = try
            Base.code_ircode_by_type(tt; optimize_until=opt_until, world=world)
        catch
            Base.code_ircode_by_type(tt; optimize_until=cfg.optimize_until, world=world)
        end
        viols = BorrowViolation[]
        callee_tts = Base.IdSet{Any}()

        for entry in codes
            ir = entry.first
            ir isa CC.IRCode || continue
            append!(viols, check_ir(ir, cfg; copy_is_new_binding=(depth > 0)))

            if (check_all || !isempty(callee_roots)) && depth < cfg.max_callee_depth
                union!(callee_tts, _collect_callee_tts(ir))
            end
        end

        isempty(viols) || throw(BorrowCheckError(tt, viols))

        if (check_all || !isempty(callee_roots)) && depth < cfg.max_callee_depth
            for ctt in callee_tts
                (ctt isa Type && ctt <: Tuple) || continue
                ctt === tt && continue
                mm = _method_match(ctt, world)
                mm === nothing && continue
                m = mm.method
                mod = m.module

                _should_check_callee_module(callee_roots, check_all, mod) || continue

                # Skip compiler-generated wrappers and kwcall plumbing; these are not
                # "user-written" code and tend to be noisy under borrow checking.
                name_str = String(m.name)
                (m.name === :kwcall || startswith(name_str, "#")) && continue

                _check_signature_recursive(
                    ctt;
                    cfg=cfg,
                    world=world,
                    depth=depth + 1,
                    callee_roots=callee_roots,
                    check_all=check_all,
                    cfg_key=cfg_key,
                )
            end
        end

        Base.@lock _checked_cache begin
            _checked_cache[][tt] = (world, cfg_key)
        end

        return true
    finally
        Base.@lock _checking_inprogress begin
            delete!(_checking_inprogress[], tt)
        end
    end
end

Base.@noinline function __bc_assert_safe__(tt::Type{<:Tuple}; cfg::Config=DEFAULT_CONFIG)
    @nospecialize tt
    check_signature(tt; cfg=cfg, world=Base.get_world_counter())
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
