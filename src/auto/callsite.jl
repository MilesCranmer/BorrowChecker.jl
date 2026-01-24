function _call_parts(stmt)
    if stmt isa Expr && stmt.head === :invoke
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

# === foreigncall / ccall helpers ===
#
# `ccall` / `llvmcall` lower to `Expr(:foreigncall, ...)`.
# The first five fields are metadata:
#   1: callee name / pointer
#   2: return type
#   3: argument types (typically a `Core.SimpleVector`, printed as `svec(...)`)
#   4: number of required args
#   5: calling convention (`:ccall`, `:llvmcall`, ...)
# The remaining fields are the C arguments followed by GC roots.

function _foreigncall_nccallargs(argtypes)
    argtypes isa QuoteNode && (argtypes = argtypes.value)
    if argtypes isa Core.SimpleVector
        return length(argtypes)
    end
    if argtypes isa Tuple || argtypes isa AbstractVector
        return length(argtypes)
    end
    if argtypes isa Expr && argtypes.head === :call && !isempty(argtypes.args)
        f = argtypes.args[1]
        if f === Core.svec ||
            f === :svec ||
            (f isa GlobalRef && f.mod === Core && f.name === :svec)
            return length(argtypes.args) - 1
        end
    end
    return 0
end

function _foreigncall_name_symbol(@nospecialize(name_expr))
    function _sym_from_tuple(@nospecialize(v))
        return if (v isa Symbol)
            v
        elseif (v isa Tuple && !isempty(v))
            _sym_from_tuple(v[1])
        else
            nothing
        end
    end

    if name_expr isa QuoteNode
        v = name_expr.value
        # Julia lowers `ccall` names in several formats depending on version, e.g.
        # - `QuoteNode(:jl_foo)`
        # - `QuoteNode((:jl_foo, "libc"))`
        # - `QuoteNode(((:jl_foo,),))` (nested tuples on newer nightlies)
        return _sym_from_tuple(v)
    end
    if name_expr isa Symbol
        return name_expr
    end
    if name_expr isa Tuple
        return _sym_from_tuple(name_expr)
    end
    if name_expr isa Expr && name_expr.head === :tuple && !isempty(name_expr.args)
        return _foreigncall_name_symbol(name_expr.args[1])
    end
    if name_expr isa Expr && name_expr.head === :call && !isempty(name_expr.args)
        # Library calls are often encoded as `Core.tuple(:name, lib)`; keep just the name.
        f = name_expr.args[1]
        if (
            f === Core.tuple ||
            f === :tuple ||
            (f isa GlobalRef && f.mod === Core && f.name === :tuple)
        ) && length(name_expr.args) >= 2
            return _foreigncall_name_symbol(name_expr.args[2])
        end
    end
    return nothing
end

function _foreigncall_parts(stmt::Expr)
    @assert stmt.head === :foreigncall

    name_sym = _foreigncall_name_symbol(stmt.args[1])

    argtypes = stmt.args[3]
    nccallargs = _foreigncall_nccallargs(argtypes)

    ccall_start = 6
    nrem = max(length(stmt.args) - (ccall_start - 1), 0)

    # If we can't parse `argtypes`, fall back conservatively: treat *all* remaining fields
    # as C arguments rather than silently dropping them as GC roots.
    if nccallargs <= 0
        nreq = stmt.args[4]
        if nreq isa Integer && nreq > 0
            nccallargs = Int(nreq)
        else
            nccallargs = nrem
        end
    end

    nccallargs = max(min(nccallargs, nrem), 0)
    if nccallargs == 0 || ccall_start > length(stmt.args)
        return name_sym, Any[], Any[], 0
    end

    ccall_stop = min(ccall_start + nccallargs - 1, length(stmt.args))
    ccall_args = stmt.args[ccall_start:ccall_stop]
    gc_roots = (ccall_stop < length(stmt.args)) ? stmt.args[(ccall_stop + 1):end] : Any[]

    return name_sym, ccall_args, gc_roots, nccallargs
end

function _foreigncall_group_used_handles(
    ccall_args, group::BitSet, ir::CC.IRCode, nargs::Int, track_arg, track_ssa
)
    used = BitSet()
    for p in group
        (1 <= p <= length(ccall_args)) || continue
        union!(used, _backward_used_handles(ccall_args[p], ir, nargs, track_arg, track_ssa))
    end
    return used
end

function _resolve_callee(@nospecialize(stmt), ir::CC.IRCode)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing
    fexpr = raw_args[1]

    try
        ft = _safe_argextype(fexpr, ir)
        return CC.singleton_type(ft)
    catch
    end

    # Some calls remain "dynamic" in IR because the callee is a mutable global binding
    # (e.g. `Main.eachindex`), even though at runtime it usually points to a concrete
    # function value like `Base.eachindex`. For `@safe`, resolve such callees from the
    # current binding to avoid spurious "unknown call" conservatism.
    if fexpr isa GlobalRef
        try
            return getfield(fexpr.mod, fexpr.name)
        catch
        end
    end
    return nothing
end

function _unwrap_unionall_datatype(@nospecialize(x))
    try
        dt = Base.unwrap_unionall(x)
        return dt isa DataType ? dt : nothing
    catch
        return nothing
    end
end

function _is_namedtuple_ctor(@nospecialize(f))::Bool
    dt = _unwrap_unionall_datatype(f)
    dt === nothing && return false
    return dt.name === Base.unwrap_unionall(NamedTuple).name
end

function _maybe_tuple_elements(@nospecialize(tup), ir::CC.IRCode)
    tup isa Core.SSAValue || return nothing
    sid = tup.id
    1 <= sid <= length(ir.stmts) || return nothing
    def = try
        ir[Core.SSAValue(sid)][:stmt]
    catch
        return nothing
    end
    def isa Expr || return nothing
    if def.head === :call
        f = _resolve_callee(def, ir)
        if f === Core.tuple
            return def.args[2:end]
        end
    elseif def.head === :tuple
        return def.args
    end
    return nothing
end

function _maybe_namedtuple_value_exprs(@nospecialize(nt), ir::CC.IRCode)
    nt = _canonical_ref(nt, ir)
    nt isa Core.SSAValue || return nothing

    sid = nt.id
    1 <= sid <= length(ir.stmts) || return nothing
    def = try
        ir[Core.SSAValue(sid)][:stmt]
    catch
        return nothing
    end
    def isa Expr || return nothing

    raw_args = if def.head === :invoke
        def.args[2:end]
    elseif def.head === :call
        def.args
    else
        return nothing
    end
    isempty(raw_args) && return nothing

    f = raw_args[1]
    if !_is_namedtuple_ctor(f)
        f2 = _resolve_callee(def, ir)
        (f2 !== nothing && _is_namedtuple_ctor(f2)) || return nothing
    end

    if length(raw_args) == 2
        return _maybe_tuple_elements(raw_args[2], ir)
    end

    return raw_args[2:end]
end

function _kwcall_value_exprs(@nospecialize(stmt), ir::CC.IRCode)
    head, _mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing

    f = _resolve_callee(stmt, ir)
    f === Core.kwcall || return nothing

    length(raw_args) >= 2 || return nothing
    return _maybe_namedtuple_value_exprs(raw_args[2], ir)
end

function _backward_used_handles(seed_expr, ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    s = BitSet()

    _collect_used_handles!(s, seed_expr, nargs, track_arg, track_ssa)

    # Walk backwards through SSA definitions starting from all SSA values referenced
    # by `seed_expr` and include any tracked handles reachable in their defining expressions.
    nstmts = length(ir.stmts)
    seed = Int[]
    _collect_ssa_ids!(seed, seed_expr)
    isempty(seed) && return s

    seen = falses(nstmts)
    work = copy(seed)
    while !isempty(work)
        sid = pop!(work)
        (1 <= sid <= nstmts) || continue
        seen[sid] && continue
        seen[sid] = true

        def = try
            ir[Core.SSAValue(sid)][:stmt]
        catch
            continue
        end

        # Do not expand through binding-barriers: they intentionally create a distinct
        # binding identity. Traversing into their argument can introduce a spurious
        # "second live binding" (e.g. the array literal SSA) and trigger false
        # uniqueness violations (especially for foreigncalls).
        if def isa Expr && (def.head === :call || def.head === :invoke)
            f = _resolve_callee(def, ir)
            if f === __bc_bind__ ||
                (isdefined(Base, :inferencebarrier) && f === Base.inferencebarrier)
                hv = _handle_index(Core.SSAValue(sid), nargs, track_arg, track_ssa)
                hv != 0 && push!(s, hv)
                continue
            end
        end

        _collect_used_handles!(s, def, nargs, track_arg, track_ssa)
        _collect_ssa_ids!(work, def)
    end

    return s
end

function _used_handles(stmt, ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    s = if stmt isa Expr && stmt.head === :foreigncall
        _backward_used_handles(stmt, ir, nargs, track_arg, track_ssa)
    else
        s = BitSet()
        _collect_used_handles!(s, stmt, nargs, track_arg, track_ssa)
        s
    end

    vals = _kwcall_value_exprs(stmt, ir)
    if vals !== nothing
        for v in vals
            _collect_used_handles!(s, v, nargs, track_arg, track_ssa)
        end
    end

    return s
end

function _kwcall_tt_from_raw_args(raw_args, ir::CC.IRCode)
    length(raw_args) >= 3 || return nothing

    fexpr = raw_args[3]
    ft = try
        _safe_argextype(fexpr, ir)
    catch
        return nothing
    end

    fobj = try
        CC.singleton_type(ft)
    catch
        nothing
    end
    if fobj === nothing
        # If inference lost the singleton, fall back to resolving a GlobalRef binding.
        if fexpr isa GlobalRef && isdefined(fexpr.mod, fexpr.name)
            fobj = getfield(fexpr.mod, fexpr.name)
        end
    end
    fobj === nothing && return nothing

    kwf = try
        Core.kwfunc(fobj)
    catch
        return nothing
    end

    # Build the kwfunc call tuple type: `kwf(kwargs, f, args...)`
    argtypes = Any[typeof(kwf)]

    # 1) kw container
    kw_t = try
        CC.widenconst(_safe_argextype(raw_args[2], ir))
    catch
        Any
    end
    push!(argtypes, (kw_t isa Type) ? kw_t : Any)

    # 2) the function value itself: use the resolved singleton's type
    f_t = (fobj isa Type) ? Type{fobj} : Core.Typeof(fobj)
    push!(argtypes, f_t)

    # 3) positional arguments
    for i in 4:length(raw_args)
        ti = try
            CC.widenconst(_safe_argextype(raw_args[i], ir))
        catch
            Any
        end
        push!(argtypes, (ti isa Type) ? ti : Any)
    end
    return Core.apply_type(Tuple, argtypes...)
end

function _maybe_box_contents_type(x::Core.SSAValue, ir::CC.IRCode)
    x = _canonical_ref(x, ir)
    stmt = try
        ir[x][:stmt]
    catch
        return Any
    end
    stmt isa Expr && stmt.head === :call || return Any
    (stmt.args[1] === Core.getfield || stmt.args[1] == GlobalRef(Core, :getfield)) ||
        return Any
    length(stmt.args) >= 3 || return Any
    fld = stmt.args[3]
    fldsym = fld isa QuoteNode ? fld.value : fld
    fldsym === :contents || return Any
    box = _canonical_ref(stmt.args[2], ir)

    # First try to recover the type from the Core.Box(init) constructor, if available.
    init_ty = Any
    if box isa Core.SSAValue
        bstmt = try
            ir[box][:stmt]
        catch
            nothing
        end
        if bstmt isa Expr &&
            bstmt.head === :call &&
            (bstmt.args[1] === Core.Box || bstmt.args[1] == GlobalRef(Core, :Box))
            if length(bstmt.args) >= 2
                init = bstmt.args[2]
                init_ty = try
                    CC.widenconst(_safe_argextype(init, ir))
                catch
                    Any
                end
                init_ty = (init_ty isa Type) ? init_ty : Any
            end
        end
    end

    # Otherwise (or additionally), look for writes to `box.contents`.
    for i in 1:length(ir.stmts)
        st = ir[Core.SSAValue(i)][:stmt]
        st isa Expr && st.head === :call || continue
        (st.args[1] === Core.setfield! || st.args[1] == GlobalRef(Core, :setfield!)) ||
            continue
        length(st.args) >= 4 || continue
        f = st.args[3]
        fsym = f isa QuoteNode ? f.value : f
        fsym === :contents || continue
        box2 = _canonical_ref(st.args[2], ir)
        box2 == box || continue
        v = st.args[4]
        t = try
            CC.widenconst(_safe_argextype(v, ir))
        catch
            Any
        end
        t = (t isa Type) ? t : Any
        # If inference lost precision (t === Any), keep searching; we may still have a useful init type.
        t === Any && continue
        return t
    end

    return init_ty
end

function _maybe_const_type_object(fexpr, ir::CC.IRCode)
    if fexpr isa GlobalRef
        v = try
            getfield(fexpr.mod, fexpr.name)
        catch
            nothing
        end
        return (v isa Type) ? v : nothing
    end
    if fexpr isa QuoteNode
        v = fexpr.value
        return (v isa Type) ? v : nothing
    end
    if fexpr isa Core.SSAValue
        def = try
            ir[fexpr][:stmt]
        catch
            nothing
        end
        def === nothing && return nothing
        return _maybe_const_type_object(def, ir)
    end
    return nothing
end

function _call_tt_from_raw_args(raw_args, ir::CC.IRCode, f_override=nothing)
    types = Any[]
    for (i, a) in enumerate(raw_args)
        t = Any
        try
            at = _safe_argextype(a, ir)
            if i == 1
                if f_override !== nothing
                    t = (f_override isa Type) ? Type{f_override} : Core.Typeof(f_override)
                else
                    fobj = _maybe_const_type_object(a, ir)
                    if fobj !== nothing
                        t = Type{fobj}
                    else
                        fval = try
                            CC.singleton_type(at)
                        catch
                            nothing
                        end
                        if fval isa Type
                            # Constructors dispatch on `Type{T}` / `Type{UnionAll(...)}` rather than
                            # `DataType`, so use the singleton type of the type object when it can be
                            # resolved.
                            t = Type{fval}
                        else
                            t = CC.widenconst(at)
                        end
                    end

                    @assert !(a isa GlobalRef) (
                        "BorrowChecker.Auto: unexpected GlobalRef callee in call signature inference. " *
                        "globalref=$(a.mod).$(a.name) inferred=$(t)"
                    )
                end
            else
                t = CC.widenconst(at)
            end
        catch
            t = Any
        end
        if t === Any && a isa Core.SSAValue
            t = _maybe_box_contents_type(a, ir)
        end
        (t isa Type) || (t = Any)
        push!(types, t)
    end
    isempty(types) && return nothing

    fT = types[1]
    if fT === Any || fT isa Union
        return nothing
    end
    dt = try
        Base.unwrap_unionall(fT)
    catch
        return nothing
    end
    dt isa DataType || return nothing
    if Base.isabstracttype(dt)
        if !(dt.name === Base.unwrap_unionall(Type).name && !isempty(dt.parameters))
            return nothing
        end
    end

    try
        return Tuple{types...}
    catch
        return nothing
    end
end
