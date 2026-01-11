struct CallSite
    stmt::Any
    head::Symbol
    mi::Any
    raw_args::Vector{Any}
    idx::Int
end

function CallSite(ctx::IRContext, idx::Int, stmt)
    if stmt isa Expr && stmt.head === :invoke
        return CallSite(stmt, :invoke, stmt.args[1], Any[stmt.args[2:end]...], idx)
    elseif stmt isa Expr && stmt.head === :call
        return CallSite(stmt, :call, nothing, Any[stmt.args...], idx)
    elseif stmt isa Expr && stmt.head === :foreigncall
        return CallSite(stmt, :foreigncall, nothing, Any[], idx)
    else
        return nothing
    end
end

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

function _resolve_callee(@nospecialize(stmt), ir::CC.IRCode)
    head, mi, raw_args = _call_parts(stmt)
    raw_args === nothing && return nothing
    fexpr = raw_args[1]

    if fexpr isa Core.Argument
        return nothing
    end

    try
        ft = CC.argextype(fexpr, ir)
        return CC.singleton_type(ft)
    catch
        return nothing
    end
end

@inline function _unwrap_unionall_datatype(@nospecialize(x))
    try
        dt = Base.unwrap_unionall(x)
        return dt isa DataType ? dt : nothing
    catch
        return nothing
    end
end

@inline function _is_namedtuple_ctor(@nospecialize(f))::Bool
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

function _used_handles(stmt, ir::CC.IRCode, nargs::Int, track_arg, track_ssa)
    s = BitSet()
    _collect_used_handles!(s, stmt, nargs, track_arg, track_ssa)

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
        CC.argextype(fexpr, ir)
    catch
        return nothing
    end

    fobj = CC.singleton_type(ft)
    fobj === nothing && return nothing

    kwf = try
        Core.kwfunc(fobj)
    catch
        return nothing
    end

    argtypes = Any[typeof(kwf)]
    for i in 2:length(raw_args)
        ti = try
            CC.widenconst(CC.argextype(raw_args[i], ir))
        catch
            Any
        end
        push!(argtypes, ti)
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
            CC.widenconst(CC.argextype(v, ir))
        catch
            Any
        end
        return (t isa Type) ? t : Any
    end

    return Any
end

function _call_tt_from_raw_args(raw_args, ir::CC.IRCode)
    types = Any[]
    for a in raw_args
        t = Any
        try
            t = CC.widenconst(CC.argextype(a, ir))
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
