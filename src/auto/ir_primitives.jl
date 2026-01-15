Base.@kwdef struct TypeTracker
    seen::Base.IdSet{Any} = Base.IdSet{Any}()
end

function (tt::TypeTracker)(@nospecialize(T))::Bool
    T === Union{} && return false
    T === Any && return true
    if T isa Union
        return any(tt, Base.uniontypes(T))
    end
    T isa Type || return true
    T === Symbol && return false

    if T <: Ptr
        return true
    end
    if T <: AbstractArray
        return true
    end
    if isdefined(Base, :RefValue) && (T <: Base.RefValue)
        return true
    end
    if isdefined(Core, :MemoryRef) && (T <: Core.MemoryRef)
        return true
    end
    if isdefined(Core, :GenericMemoryRef) && (T <: Core.GenericMemoryRef)
        return true
    end
    if isdefined(Core, :GenericMemory) && (T <: Core.GenericMemory)
        return true
    end

    dt = Base.unwrap_unionall(T)
    if dt isa DataType
        if isdefined(Core, :Box) && (dt === Core.Box || T <: Core.Box)
            return false
        end
        Base.isconcretetype(dt) || return true

        Base.ismutabletype(dt) && return true
        if Base.isbitstype(dt)
            # Most bitstypes are pure values. However, some bitstypes (notably tuples/structs
            # that contain `Ptr`) represent references into mutable memory and need tracking
            # for IR-level effects (e.g. BLAS `ccall` lowering through pointer tuples).
            return any(tt, fieldtypes(dt))
        end

        if dt in tt.seen
            return true
        end
        push!(tt.seen, dt)
        return any(tt, fieldtypes(dt))
    end
    return true
end

is_tracked_type(@nospecialize T)::Bool = TypeTracker()(T)

# "Tracking" answers: should we include this value in alias/liveness tracking?
#
# For move-like checks we also need a notion of "owned" values. Some low-level compiler
# artifacts (e.g. `Core.MemoryRef`) behave more like borrows of an owned object rather than
# independently-owned resources.
Base.@kwdef struct OwnedTypeTracker
    seen::Base.IdSet{Any} = Base.IdSet{Any}()
end

function _is_nonowning_ref_type(@nospecialize(T))::Bool
    if isdefined(Core, :MemoryRef) && (T <: Core.MemoryRef)
        return true
    end
    if isdefined(Core, :GenericMemoryRef) && (T <: Core.GenericMemoryRef)
        return true
    end
    if isdefined(Core, :GenericMemory) && (T <: Core.GenericMemory)
        return true
    end
    if T <: Ptr
        return true
    end
    return false
end

function (tt::OwnedTypeTracker)(@nospecialize(T))::Bool
    T === Union{} && return false
    T === Any && return true
    T isa Union && return any(tt, Base.uniontypes(T))
    T isa Type || return true
    T === Symbol && return false
    T <: Module && return false
    # Type objects (`DataType`, `UnionAll`, `TypeVar`, ...) are globally shared and
    # should not participate in ownership/move rules.
    T <: Type && return false

    _is_nonowning_ref_type(T) && return false

    dt = Base.unwrap_unionall(T)
    if dt isa DataType
        if isdefined(Core, :Box) && (dt === Core.Box || T <: Core.Box)
            return false
        end
        Base.isconcretetype(dt) || return true

        Base.ismutabletype(dt) && return true
        Base.isbitstype(dt) && return false

        if dt in tt.seen
            return true
        end
        push!(tt.seen, dt)
        return any(tt, fieldtypes(dt))
    end
    return true
end

is_owned_type(@nospecialize T)::Bool = OwnedTypeTracker()(T)

@inline _ssa_handle(nargs::Int, id::Int) = nargs + id
@inline _arg_handle(id::Int) = id

function _handle_index(
    x, nargs::Int, track_arg::AbstractVector{Bool}, track_ssa::AbstractVector{Bool}
)
    if x isa Core.Argument
        n = x.n
        return (1 <= n <= length(track_arg) && track_arg[n]) ? _arg_handle(n) : 0
    elseif x isa Core.SSAValue
        i = x.id
        return (1 <= i <= length(track_ssa) && track_ssa[i]) ? _ssa_handle(nargs, i) : 0
    else
        return 0
    end
end

function _inst_get(@nospecialize(inst), sym::Symbol, default=nothing)
    try
        return inst[sym]
    catch
    end
    if Base.hasproperty(inst, sym)
        return getproperty(inst, sym)
    end
    return default
end

function _lineinfo_from_debuginfo(ir::CC.IRCode, pc::Int)
    pc <= 0 && return nothing
    builder = if isdefined(CC, :IRShow) && isdefined(CC.IRShow, :buildLineInfoNode)
        CC.IRShow.buildLineInfoNode
    elseif isdefined(CC, :buildLineInfoNode)
        CC.buildLineInfoNode
    else
        nothing
    end
    builder === nothing && return nothing
    try
        di = getproperty(ir, :debuginfo)
        stack = builder(di, nothing, pc)
        isempty(stack) && return nothing
        chosen = nothing
        for node in stack
            file = try
                getproperty(node, :file)
            catch
                nothing
            end
            line = try
                getproperty(node, :line)
            catch
                nothing
            end
            if file isa Symbol &&
                line isa Integer &&
                line > 0 &&
                file !== Symbol("none") &&
                file !== Symbol("unknown")
                chosen = node
                break
            end
        end

        chosen === nothing && return nothing
        file = getproperty(chosen, :file)::Symbol
        line = getproperty(chosen, :line)::Integer
        return LineNumberNode(Int(line), file)
    catch
        return nothing
    end
end

function _normalize_lineinfo(ir::CC.IRCode, li, pc::Int=0)
    if li isa Core.LineInfoNode
        file = try
            String(getproperty(li, :file))
        catch
            ""
        end
        line = try
            Int(getproperty(li, :line))
        catch
            0
        end
        if !isempty(file) && file != "none" && file != "unknown" && line > 0
            return li
        end
    elseif li isa LineNumberNode
        if li.line > 0 && li.file !== Symbol("none") && li.file !== Symbol("unknown")
            return li
        end
    end

    if pc > 0
        tmp = _lineinfo_from_debuginfo(ir, pc)
        tmp !== nothing && return tmp
    end

    if li isa Integer
        lii = Int(li)
        lii <= 0 && return nothing
        if Base.hasproperty(ir, :linetable)
            linetable = getproperty(ir, :linetable)
            if lii <= length(linetable)
                linfo = linetable[lii]
                return (linfo isa Core.LineInfoNode) ? linfo : nothing
            end
        end
        return nothing
    elseif li isa NTuple{3,<:Integer}
        return _lineinfo_from_debuginfo(ir, Int(li[1]))
    end

    return nothing
end

function _stmt_lineinfo(ir::CC.IRCode, idx::Int)
    try
        inst = ir[Core.SSAValue(idx)]
        li = _inst_get(inst, :line, nothing)
        return _normalize_lineinfo(ir, li, idx)
    catch
        return nothing
    end
end

mutable struct UnionFind
    parent::Vector{Int}
    rank::Vector{UInt8}
end

function UnionFind(n::Int)
    parent = collect(1:n)
    rank = fill(UInt8(0), n)
    return UnionFind(parent, rank)
end

function _uf_find(uf::UnionFind, x::Int)
    p = uf.parent[x]
    if p == x
        return x
    end
    r = _uf_find(uf, p)
    uf.parent[x] = r
    return r
end

function _uf_union!(uf::UnionFind, a::Int, b::Int)
    ((a == 0) || (b == 0) || (a == b)) && return nothing
    ra = _uf_find(uf, a)
    rb = _uf_find(uf, b)
    ra == rb && return nothing
    if uf.rank[ra] < uf.rank[rb]
        uf.parent[ra] = rb
    elseif uf.rank[ra] > uf.rank[rb]
        uf.parent[rb] = ra
    else
        uf.parent[rb] = ra
        uf.rank[ra] += 1
    end
    return nothing
end

@inline function _phi_values(@nospecialize(x))
    if Base.hasproperty(x, :values)
        return getproperty(x, :values)
    end
    if Base.hasproperty(x, :vals)
        return getproperty(x, :vals)
    end
    return ()
end

function _collect_used_handles!(s::BitSet, x, nargs::Int, track_arg, track_ssa)
    if x isa Core.PhiNode
        vals = _phi_values(x)
        if vals isa AbstractArray
            for k in eachindex(vals)
                isassigned(vals, k) || continue
                _collect_used_handles!(s, vals[k], nargs, track_arg, track_ssa)
            end
        else
            for v in vals
                _collect_used_handles!(s, v, nargs, track_arg, track_ssa)
            end
        end
        return nothing
    end
    if isdefined(Core, :PhiCNode) && x isa Core.PhiCNode
        vals = _phi_values(x)
        if vals isa AbstractArray
            for k in eachindex(vals)
                isassigned(vals, k) || continue
                _collect_used_handles!(s, vals[k], nargs, track_arg, track_ssa)
            end
        else
            for v in vals
                _collect_used_handles!(s, v, nargs, track_arg, track_ssa)
            end
        end
        return nothing
    end
    if x isa Core.Argument || x isa Core.SSAValue
        h = _handle_index(x, nargs, track_arg, track_ssa)
        h != 0 && push!(s, h)
        return nothing
    end
    if x isa Core.ReturnNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.PiNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.UpsilonNode
        if isdefined(x, :val)
            _collect_used_handles!(s, getfield(x, :val), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Core.GotoIfNot
        if isdefined(x, :cond)
            _collect_used_handles!(s, getfield(x, :cond), nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Expr
        for a in x.args
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa Tuple
        for a in x
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    if x isa AbstractArray
        for a in x
            _collect_used_handles!(s, a, nargs, track_arg, track_ssa)
        end
        return nothing
    end
    return nothing
end

function _collect_ssa_ids!(ids::Vector{Int}, x)
    if x isa Core.PhiNode
        for v in _phi_values(x)
            _collect_ssa_ids!(ids, v)
        end
        return nothing
    end
    if isdefined(Core, :PhiCNode) && x isa Core.PhiCNode
        for v in _phi_values(x)
            _collect_ssa_ids!(ids, v)
        end
        return nothing
    end
    if x isa Core.SSAValue
        push!(ids, x.id)
        return nothing
    end
    if x isa Core.ReturnNode
        if isdefined(x, :val)
            _collect_ssa_ids!(ids, getfield(x, :val))
        end
        return nothing
    end
    if x isa Core.PiNode
        if isdefined(x, :val)
            _collect_ssa_ids!(ids, getfield(x, :val))
        end
        return nothing
    end
    if x isa Core.UpsilonNode
        if isdefined(x, :val)
            _collect_ssa_ids!(ids, getfield(x, :val))
        end
        return nothing
    end
    if x isa Core.GotoIfNot
        if isdefined(x, :cond)
            _collect_ssa_ids!(ids, getfield(x, :cond))
        end
        return nothing
    end
    if x isa Expr
        for a in x.args
            _collect_ssa_ids!(ids, a)
        end
        return nothing
    end
    if x isa Tuple
        for a in x
            _collect_ssa_ids!(ids, a)
        end
        return nothing
    end
    if x isa AbstractArray
        for a in x
            _collect_ssa_ids!(ids, a)
        end
        return nothing
    end
    return nothing
end

function _canonical_ref(@nospecialize(x), ir::CC.IRCode)
    while x isa Core.SSAValue
        stmt = try
            ir[x][:stmt]
        catch
            break
        end
        if stmt isa Core.SSAValue
            x = stmt
            continue
        end
        if stmt isa Core.PiNode
            x = stmt.val
            continue
        end
        break
    end
    return x
end

function compute_tracking_masks(ir::CC.IRCode)
    nargs = length(ir.argtypes)
    nstmts = length(ir.stmts)

    track_arg = Vector{Bool}(undef, nargs)
    for a in 1:nargs
        T = try
            CC.widenconst(ir.argtypes[a])
        catch
            Any
        end
        track_arg[a] = is_tracked_type(T)
    end

    track_ssa = Vector{Bool}(undef, nstmts)
    for i in 1:nstmts
        T = try
            inst = ir[Core.SSAValue(i)]
            CC.widenconst(_inst_get(inst, :type, Any))
        catch
            Any
        end
        track_ssa[i] = is_tracked_type(T)
    end

    return track_arg, track_ssa
end
