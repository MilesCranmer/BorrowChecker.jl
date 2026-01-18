"""BorrowChecker.Auto: IR type refinement.

Julia's type inference sometimes intentionally loses precision around boxed captured
variables (`Core.Box`) and inference barriers. That is correct for the compiler, but it
hurts BorrowChecker's ability to resolve call targets and avoid spurious "unknown call"
effects.

This file implements a small, conservative refinement pass that *only* uses Core
semantics:

* Track `Core.Box` contents types from their constructors and (non-`Any`) writes.
* Refine `getfield(box, :contents)` return types using that tracked contents type.
* Refine `getfield(x, :field)` return types when `x` has a concrete type and the field
  name/index is statically known.

The pass never attempts to interpret overloadable Base operations like `getproperty`.
"""

# NOTE: This file is included from `auto_ir.jl` after `summaries.jl` and
# `ir_primitives.jl`, so we can use internal helpers like `_inst_get` and
# `_canonical_ref`.

const _MaybeType = Union{Nothing, Type}

@inline function _as_type_or_any(@nospecialize(T))::Type
    T = CC.widenconst(T)
    return (T isa Type) ? T : Any
end

@inline function _widen_type_slot(@nospecialize(T))
    # IR type slots can contain lattice elements; we only need the widened type.
    return CC.widenconst(T)
end

@inline function _is_any_slot(@nospecialize(T))::Bool
    return _widen_type_slot(T) === Any
end

@inline function _field_is_contents(field_expr)::Bool
    if field_expr isa QuoteNode
        return field_expr.value === :contents
    end
    return field_expr === :contents
end

@inline function _field_is_const_symbol(field_expr)
    if field_expr isa QuoteNode
        v = field_expr.value
        return (v isa Symbol) ? v : nothing
    end
    return (field_expr isa Symbol) ? field_expr : nothing
end

@inline function _field_is_const_int(field_expr)
    if field_expr isa QuoteNode
        v = field_expr.value
        return (v isa Integer) ? Int(v) : nothing
    end
    return (field_expr isa Integer) ? Int(field_expr) : nothing
end

function _fieldtype_if_known(@nospecialize(objT), field_expr)
    objT = _as_type_or_any(objT)
    objT === Any && return nothing
    dt = Base.unwrap_unionall(objT)
    dt isa DataType || return nothing

    # Only refine for concrete object types. (If inference didn't narrow it, we won't.)
    Base.isconcretetype(dt) || return nothing

    # Symbol field
    sym = _field_is_const_symbol(field_expr)
    if sym !== nothing
        return try
            Base.fieldtype(dt, sym)
        catch
            nothing
        end
    end

    # Integer index field
    idx = _field_is_const_int(field_expr)
    if idx !== nothing
        return try
            Base.fieldtype(dt, idx)
        catch
            nothing
        end
    end

    return nothing
end

function _is_box_ctor(stmt, ir::CC.IRCode)
    stmt isa Expr || return false
    stmt.head === :call || return false
    isempty(stmt.args) && return false
    f = stmt.args[1]

    # Resolve the callee; we only treat the *actual* Core.Box constructor as a box.
    fobj = _resolve_callee(stmt, ir)
    return fobj === Core.Box
end

function _is_builtin_getfield_call(stmt, ir::CC.IRCode)
    stmt isa Expr || return false
    stmt.head === :call || return false
    length(stmt.args) >= 3 || return false
    fobj = _resolve_callee(stmt, ir)
    return fobj === Core.getfield
end

function _is_builtin_setfield_call(stmt, ir::CC.IRCode)
    stmt isa Expr || return false
    stmt.head === :call || return false
    length(stmt.args) >= 4 || return false
    fobj = _resolve_callee(stmt, ir)
    return fobj === Core.setfield!
end

function _maybe_set_inst_type!(ir::CC.IRCode, idx::Int, newT::Type)::Bool
    newT === Any && return false
    inst = ir.stmts[idx]
    cur = _inst_get(inst, :type, Any)
    _is_any_slot(cur) || return false

    # Use the instruction indexing API, which is stable across Julia versions.
    try
        inst[:type] = newT
    catch
        # Fallback for older IR representations.
        try
            setproperty!(inst, :type, newT)
        catch
            return false
        end
    end
    return true
end

@inline function _join_box_type(old::Type, new::Type)::Type
    # Ignore uninformative `Any` writes, otherwise merge.
    new === Any && return old
    old === Any && return new
    return Base.typejoin(old, new)
end

"""Refine types in-place.

This pass is intentionally small and conservative; it is only used to recover precision
around boxed captured variables and concrete field accesses.
"""
function refine_types!(ir::CC.IRCode, cfg::Config)
    n = length(ir.stmts)
    n == 0 && return ir

    # Map `SSAValue` ids that hold a `Core.Box` object to their best-known `:contents` type.
    box_contents = Vector{_MaybeType}(undef, n)
    fill!(box_contents, nothing)

    # A few iterations are enough for simple forward propagation.
    max_iter = 3
    for _iter in 1:max_iter
        changed = false

        for i in 1:n
            inst = ir.stmts[i]
            stmt = _inst_get(inst, :stmt, nothing)
            stmt === nothing && continue

            # (1) Track box init types.
            if _is_box_ctor(stmt, ir)
                initT = Any
                if length(stmt.args) >= 2
                    initT = _as_type_or_any(_safe_argextype(stmt.args[2], ir))
                end
                old = box_contents[i]
                if old === nothing
                    box_contents[i] = initT
                    changed = true
                else
                    new = _join_box_type(old::Type, initT)
                    if new !== old
                        box_contents[i] = new
                        changed = true
                    end
                end
            end

            # (2) Track writes to `box.contents`.
            if _is_builtin_setfield_call(stmt, ir)
                # setfield!(obj, field, val)
                obj = _canonical_ref(stmt.args[2], ir)
                field = stmt.args[3]
                if obj isa Core.SSAValue && _field_is_contents(field)
                    bid = obj.id
                    # Only track boxes we already recognized (via constructor).
                    old = box_contents[bid]
                    if old !== nothing
                        valT = _as_type_or_any(_safe_argextype(stmt.args[4], ir))
                        new = _join_box_type(old::Type, valT)
                        if new !== old
                            box_contents[bid] = new
                            changed = true
                        end
                    end
                end
            end

            # (3) Refine `getfield(box, :contents)`.
            if _is_builtin_getfield_call(stmt, ir)
                obj = _canonical_ref(stmt.args[2], ir)
                field = stmt.args[3]

                if obj isa Core.SSAValue && _field_is_contents(field)
                    bid = obj.id
                    bt = box_contents[bid]
                    if bt !== nothing
                        changed |= _maybe_set_inst_type!(ir, i, bt::Type)
                        continue
                    end
                end

                # (4) Refine concrete struct field loads: getfield(x, :n) where typeof(x) is concrete.
                if _is_any_slot(_inst_get(inst, :type, Any))
                    objT = _as_type_or_any(_safe_argextype(obj, ir))
                    ft = _fieldtype_if_known(objT, field)
                    ft !== nothing && (changed |= _maybe_set_inst_type!(ir, i, ft))
                end
            end
        end

        changed || break
    end

    return ir
end
