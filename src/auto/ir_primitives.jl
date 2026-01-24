Base.@kwdef struct TypeTracker
    seen::Base.IdSet{Any} = Base.IdSet{Any}()
end

"""
    _is_shareable_handle_type(T) -> Bool

Return `true` for types that behave like shareable concurrency handles.

These values routinely escape into globally-reachable runtime state (e.g. scheduler
queues) as an implementation detail, while remaining safe to use via additional
aliases held by user code. They should not participate in `@safe`'s Rust-like
ownership/move rules.
"""
function _is_shareable_handle_type(@nospecialize(T))::Bool
    # Type slots in `IRCode` may contain compiler lattice elements
    # (e.g. `Core.PartialStruct`, `Core.Const`, ...). Only actual Julia `Type`s
    # are eligible for this shareable-handle fast-path.
    T isa Type || return false

    # Task handles are stored in the scheduler run queues by `@async`/`schedule`.
    (T <: Task) && return true

    # Atomics provide synchronized interior mutability and are intended to be aliased.
    if isdefined(Base, :Threads) && isdefined(Base.Threads, :Atomic)
        (T <: Base.Threads.Atomic) && return true
    end

    return false
end

function (tt::TypeTracker)(@nospecialize(T))::Bool
    T === Union{} && return false
    T === Any && return true
    if T isa Union
        return any(tt, Base.uniontypes(T))
    end

    @assert (T isa Type) (
        "BorrowChecker.Auto: expected `Type` in TypeTracker, got $(typeof(T))"
    )

    if T isa UnionAll
        return tt(Base.unwrap_unionall(T))
    end
    T === Symbol && return false

    # Modules and type objects are globally-shareable handles.
    # Treat them as *not tracked* so they don't participate in move/consume rules.
    (T <: Module) && return false
    (T <: Type) && return false

    _is_shareable_handle_type(T) && return false

    # Low-level references. We treat these as tracked because they can point to mutable
    # memory even though the value itself is isbits.
    if T <: Ptr
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
            # Some low-level compiler artifacts behave more like borrows than owned resources.
            return false
        end
        Base.isconcretetype(dt) || return true
        Base.ismutabletype(dt) && return true
        if Base.isbitstype(dt)
            return any(tt, fieldtypes(dt))
        end
        dt in tt.seen && return true
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

    @assert (T isa Type) (
        "BorrowChecker.Auto: expected `Type` in OwnedTypeTracker, got $(typeof(T))"
    )

    if T isa UnionAll
        return tt(Base.unwrap_unionall(T))
    end
    T === Symbol && return false

    # Modules and type objects are globally-shareable handles.
    # Treat them as *not owned* so unknown/dynamic calls don't spuriously consume them.
    (T <: Module) && return false
    (T <: Type) && return false

    _is_shareable_handle_type(T) && return false

    # These low-level reference types are never treated as owned.
    if T <: Ptr
        return false
    end
    if isdefined(Base, :RefValue) && (T <: Base.RefValue)
        return false
    end
    if isdefined(Core, :MemoryRef) && (T <: Core.MemoryRef)
        return false
    end
    if isdefined(Core, :GenericMemoryRef) && (T <: Core.GenericMemoryRef)
        return false
    end
    if isdefined(Core, :GenericMemory) && (T <: Core.GenericMemory)
        return false
    end

    dt = Base.unwrap_unionall(T)
    if dt isa DataType
        if isdefined(Core, :Box) && (dt === Core.Box || T <: Core.Box)
            # Some low-level compiler artifacts behave more like borrows than owned resources.
            return false
        end
        Base.isconcretetype(dt) || return true
        Base.ismutabletype(dt) && return true
        Base.isbitstype(dt) && return false
        dt in tt.seen && return true
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

@inline function _safe_argextype(@nospecialize(x), ir::CC.IRCode)
    # `Core.Compiler.argextype` expects a valid IR argument (SSAValue/Argument/Const/...),
    # not an `Expr(:call, ...)`. On newer Julia versions this can throw/warn loudly.
    x isa Expr && return Any
    return CC.argextype(x, ir)
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

function _collect_linenodes!(acc::Set{Tuple{Symbol,Int}}, ex)
    if ex isa LineNumberNode
        ex.line > 0 && push!(acc, (ex.file, Int(ex.line)))
        return acc
    elseif ex isa Expr
        for a in ex.args
            _collect_linenodes!(acc, a)
        end
        return acc
    else
        return acc
    end
end

"""Count top-level statements in a `:block` AST by their active (file,line).

This is used to disambiguate cases where unsafe and safe statements share a source line
(e.g. `@unsafe ...; stmt`). We conservatively assume the unsafe region corresponds to the
first `k` statement locations on that line, where `k` is the number of top-level
statements in the unsafe block for that line.
"""
function _unsafe_prefix_counts_from_block!(acc::Dict{Tuple{Symbol,Int},Int}, ex)
    line = nothing
    if ex isa Expr && ex.head === :block
        for a in ex.args
            if a isa LineNumberNode
                a.line > 0 && (line = (a.file, Int(a.line)))
                continue
            end
            if a isa Expr && a.head === :line
                continue
            end
            line === nothing && continue
            acc[line] = get(acc, line, 0) + 1
        end
    end
    return acc
end

function _line_tuple(li)::Union{Nothing,Tuple{Symbol,Int}}
    @assert li isa LineNumberNode
    return (li.file, Int(li.line))
end

function _raw_line_id(ir::CC.IRCode, idx::Int)
    inst = ir[Core.SSAValue(idx)]
    return _inst_get(inst, :line, nothing)
end

"""Return a statement mask `unsafe_stmt[i]` indicating that IR stmt `i` is inside an `@unsafe` region."""
function _unsafe_stmt_mask(ir::CC.IRCode)::Vector{Bool}
    nstmts = length(ir.stmts)
    (nstmts == 0) && return Bool[]

    meta = getproperty(ir, :meta)

    # If a method contains a bare `Expr(:meta, :borrow_checker_unsafe)`, treat the entire
    # method body as unchecked.
    all_unsafe = false
    linenodes = Set{Tuple{Symbol,Int}}()
    prefix_counts = Dict{Tuple{Symbol,Int},Int}()

    for m in meta
        (m isa Expr && m.head === :meta && !isempty(m.args)) || continue
        m.args[1] === BC_UNSAFE_META || continue
        if length(m.args) == 1
            all_unsafe = true
            break
        end
        # Convention: `Expr(:meta, :borrow_checker_unsafe, <block-ast>)`
        blk = m.args[2]
        _collect_linenodes!(linenodes, blk)
        _unsafe_prefix_counts_from_block!(prefix_counts, blk)
    end

    all_unsafe && return trues(nstmts)
    isempty(linenodes) && return falses(nstmts)

    # Collect, for each unsafe (file,line), the ordered list of distinct low-level
    # location IDs that appear on that line in IR.
    raw_order = Dict{Tuple{Symbol,Int},Vector{Any}}()
    raw_seen = Dict{Tuple{Symbol,Int},Set{Any}}()

    for i in 1:nstmts
        li = _stmt_lineinfo(ir, i)
        lt = (li === nothing) ? nothing : _line_tuple(li)
        lt === nothing && continue
        lt in linenodes || continue

        stmt = ir[Core.SSAValue(i)][:stmt]
        stmt === nothing && continue

        raw = _raw_line_id(ir, i)
        raw === nothing && continue
        (raw isa Integer && raw == 0) && continue

        seen = get!(raw_seen, lt, Set{Any}())
        if !(raw in seen)
            push!(get!(raw_order, lt, Any[]), raw)
            push!(seen, raw)
        end
    end

    # Decide, per unsafe (file,line), whether we can mask the whole line or need to
    # disambiguate using a prefix of statement locations.
    full_line = Set{Tuple{Symbol,Int}}()
    raw_prefix = Dict{Tuple{Symbol,Int},Set{Any}}()

    for lt in linenodes
        k = get(prefix_counts, lt, nothing)
        raw_ids = get(raw_order, lt, nothing)

        if k === nothing || raw_ids === nothing || isempty(raw_ids)
            push!(full_line, lt)
            continue
        end

        if k >= length(raw_ids)
            push!(full_line, lt)
            continue
        end

        s = Set{Any}()
        for j in 1:k
            push!(s, raw_ids[j])
        end
        raw_prefix[lt] = s
    end

    unsafe_stmt = falses(nstmts)
    for i in 1:nstmts
        li = _stmt_lineinfo(ir, i)
        lt = (li === nothing) ? nothing : _line_tuple(li)
        lt === nothing && continue
        lt in linenodes || continue

        if lt in full_line
            unsafe_stmt[i] = true
            continue
        end

        raw = _raw_line_id(ir, i)
        (raw === nothing || (raw isa Integer && raw == 0)) &&
            (unsafe_stmt[i] = true; continue)

        ids = get(raw_prefix, lt, nothing)
        (ids !== nothing && raw in ids) && (unsafe_stmt[i] = true)
    end
    return unsafe_stmt
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
