# Experiment 2: borrow-check-gated COMPILE-TIME TRANSFORMATION of allocations.
#
# Experiment 1 showed `@safe` can *verify* hand-written arena code. Here we go
# the other way: take ordinary Julia code that allocates `Vector`s, prove at
# the IR level that an allocation never escapes the function, and REWRITE the
# compiled IR so that allocation comes from a bump arena instead of the GC
# heap. The user writes plain Julia; the GC never sees the array data.
#
# Pipeline (all at compile time of the specialization, mirroring how `@safe`
# stages itself into compilation):
#
#   1. Gate: run BorrowChecker's `@safe` check (`Auto.check_signature`) on the
#      specialization. If the Rust-like borrow check fails, do not transform.
#   2. Fetch the fully optimized `IRCode` (post-inlining) via
#      `Base.code_ircode_by_type`.
#   3. For each `Core.memorynew(Memory{T}, n)` site with isbits `T`, compute
#      the set of values *derived* from it (the Vector `%new` wrapper,
#      `memoryrefnew`s, `getfield`s, phis, ...) and check every use of every
#      member against a whitelist of non-escaping operations. A use in a
#      `ReturnNode`, an unknown call, or as the *stored value* of any write
#      rejects the site. The polarity is the safe one: anything unproven
#      stays on the GC heap.
#   4. Rewrite proven `memorynew` calls to `arena_memorynew` (bump-allocate
#      from Bumper's buffer, `unsafe_wrap` a `Memory{T}` around the pointer)
#      and compile the result as a `Core.OpaqueClosure`.
#   5. Wrap the closure in an arena checkpoint save/restore, so all swapped
#      allocations are reclaimed *deterministically* when the call returns:
#      ownership told us where the free goes -- no GC needed.
#
# Known soundness caveats of the prototype (documented, not hidden):
#   * A bounds-error path stores the array in the thrown `BoundsError`. We
#     allow uses in throwing (`Union{}`-typed) calls; if a caller catches the
#     exception and reads `err.a`, that's a use-after-free. (Run the kernel
#     with `@inbounds`, or treat exceptions as fatal, to close this.)
#   * Tasks/closures created inside the kernel are rejected as unknown calls,
#     so cross-task escapes can't sneak through the whitelist.
#
# Run with: julia --project=experiments experiments/02_gc_free_transform.jl

import BorrowChecker
using BorrowChecker.Auto: BorrowCheckError
const Auto = BorrowChecker.Auto

module GCFreeTransform

using Bumper: Bumper, default_buffer, alloc_ptr!, checkpoint_save, checkpoint_restore!
import BorrowChecker
const Auto = BorrowChecker.Auto
const CC = Core.Compiler

export gc_free

"""
    arena_memorynew(::Type{Memory{T}}, n) -> Memory{T}

Drop-in replacement for the `Core.memorynew` builtin: the data buffer comes
from the task-local bump arena instead of the GC heap. Only the small
`Memory` header object is GC-allocated. Reclamation happens when the
enclosing [`GCFreeKernel`](@ref) call restores its arena checkpoint.
"""
@noinline function arena_memorynew(::Type{Memory{T}}, n::Integer) where {T}
    nb = Int(n) * sizeof(T)
    ptr = alloc_ptr!(default_buffer(), nb)
    return unsafe_wrap(Memory{T}, Ptr{T}(ptr), Int(n))
end

# --- IR helpers -------------------------------------------------------------

_isexpr(x, head) = x isa Expr && x.head === head

function _callee_value(stmt::Expr)
    f = stmt.args[1]
    f isa GlobalRef && return isdefined(f.mod, f.name) ? getfield(f.mod, f.name) : nothing
    f isa QuoteNode && return f.value
    f isa Function && return f
    f isa Core.Builtin && return f
    return nothing
end

_is_memorynew(stmt) =
    _isexpr(stmt, :call) && _callee_value(stmt) === Core.memorynew && length(stmt.args) == 3

function _stmt_uses(stmt)
    ssas = Int[]
    for ur in CC.userefs(stmt)
        v = ur[]
        v isa Core.SSAValue && push!(ssas, v.id)
    end
    return ssas
end

_stmt_type(ir, i) = CC.widenconst(ir[Core.SSAValue(i)][:type])

# Can a value of type `T` hold (a reference to) the allocation? Values that
# provably cannot (lengths, flags, size tuples, element values of an isbits
# eltype) need not join the derived set, which keeps integer arithmetic on
# e.g. `length(v)` out of the escape check.
function _type_carries_alloc(@nospecialize T)::Bool
    T = CC.widenconst(T)
    T === Union{} && return false
    T isa Union && return _type_carries_alloc(T.a) || _type_carries_alloc(T.b)
    T isa UnionAll && return true  # not concrete enough to rule out
    Base.isconcretetype(T) || return true
    (T <: GenericMemory || T <: GenericMemoryRef || T <: AbstractArray || T <: Ptr) &&
        return true
    Base.ismutabletype(T) && return true
    return any(_type_carries_alloc, fieldtypes(T))
end

# Operations through which "the allocation" propagates: the result must join
# the derived set so its own uses get checked.
function _is_deriving(ir, i, stmt, derived)::Bool
    _type_carries_alloc(_stmt_type(ir, i)) || return false
    stmt isa Core.PhiNode && return true
    stmt isa Core.PiNode && return true
    _isexpr(stmt, :new) && return true
    if _isexpr(stmt, :call)
        f = _callee_value(stmt)
        return f in (Core.memoryrefnew, Core.memoryref, Base.getfield, Core.getfield,
            Core.tuple)
    end
    return false
end

# Pure, non-escaping uses of a derived value (when used at allowed positions).
function _use_is_safe(ir, i, stmt, derived::BitSet)::Bool
    stmt isa Core.PhiNode && return true  # phi joins derived set
    stmt isa Core.PiNode && return true
    i in derived && return true           # deriving stmt itself
    if _isexpr(stmt, :call)
        f = _callee_value(stmt)
        f === nothing && return false
        # Reads / metadata: never let the pointer out.
        f in (
            Core.memoryrefget, Core.memoryrefoffset, Base.getfield, Core.getfield,
            Core.memoryrefnew, Core.memoryref, Core.sizeof, Base.sizeof,
            Core.:(===), Core.isa, Core.typeof, Base.donotdelete,
        ) && return true
        if f === Core.memoryrefset!
            # memoryrefset!(ref, value, order, boundscheck): writing INTO the
            # arena array is fine; storing a derived value (args[3]) INTO
            # some other ref would be an escape.
            for k in 3:length(stmt.args)
                a = stmt.args[k]
                a isa Core.SSAValue && a.id in derived && return false
            end
            return true
        end
        return false
    end
    if _isexpr(stmt, :invoke)
        # Allow only throwing calls (Union{} return): the value can escape
        # into the exception object -- see the caveat at the top of the file.
        return _stmt_type(ir, i) === Union{}
    end
    if _isexpr(stmt, :boundscheck) ||
        _isexpr(stmt, :gc_preserve_begin) ||
        _isexpr(stmt, :gc_preserve_end)
        return true
    end
    return false
end

"""
    _provably_local(ir, alloc_idx) -> Bool

Escape analysis for one `memorynew` site: compute the transitive derived set
and check that every use of every member is whitelisted-safe.
"""
function _provably_local(ir::CC.IRCode, alloc_idx::Int)::Bool
    n = length(ir.stmts)
    derived = BitSet((alloc_idx,))

    changed = true
    while changed
        changed = false
        for i in 1:n
            i in derived && continue
            stmt = ir[Core.SSAValue(i)][:stmt]
            stmt === nothing && continue
            uses = _stmt_uses(stmt)
            if any(in(derived), uses) && _is_deriving(ir, i, stmt, derived)
                push!(derived, i)
                changed = true
            end
        end
    end

    for i in 1:n
        stmt = ir[Core.SSAValue(i)][:stmt]
        stmt === nothing && continue
        uses = _stmt_uses(stmt)
        any(in(derived), uses) || continue
        if stmt isa Core.ReturnNode || stmt isa Core.GotoIfNot
            return false  # escapes via return / influences control as a pointer
        end
        _use_is_safe(ir, i, stmt, derived) || return false
    end
    return true
end

# --- the transformer --------------------------------------------------------

struct GCFreeKernel{OC}
    oc::OC
    nswapped::Int
    nrejected::Int
end

function (k::GCFreeKernel)(args...)
    buf = default_buffer()
    cp = checkpoint_save(buf)
    try
        return k.oc(args...)
    finally
        # Deterministic reclamation: ownership analysis proved every swapped
        # allocation dies before the call returns, so this is the drop point.
        checkpoint_restore!(cp)
    end
end

"""
    gc_free(f, argtypes::Type{<:Tuple}; borrow_check=true) -> GCFreeKernel

Compile a GC-free version of `f` for the given argument types. Allocations
proven non-escaping are rewritten to arena allocations; everything else is
left on the GC heap (the safe fallback direction).
"""
function gc_free(f, argtypes::Type{<:Tuple}; borrow_check::Bool=true, verbose::Bool=true)
    tt = Base.signature_type(f, argtypes)

    if borrow_check
        # Gate: the Rust-like borrow check must pass before we trust the
        # aliasing structure of this code enough to move its allocations.
        Auto.check_signature(tt)  # throws BorrowCheckError on violation
    end

    codes = Base.code_ircode_by_type(tt)
    isempty(codes) && error("no method instance for $tt")
    ir, _rt = only(codes)

    nswapped = 0
    nrejected = 0
    for i in 1:length(ir.stmts)
        stmt = ir[Core.SSAValue(i)][:stmt]
        _is_memorynew(stmt) || continue
        MemT = CC.widenconst(_stmt_type(ir, i))
        elT = eltype(MemT)
        if !isbitstype(elT)
            nrejected += 1
            verbose && println("  [gc_free] reject %$i: eltype $elT is not isbits")
            continue
        end
        if _provably_local(ir, i)
            inst = ir[Core.SSAValue(i)]
            inst[:stmt] = Expr(:call, arena_memorynew, stmt.args[2], stmt.args[3])
            inst[:flag] = zero(inst[:flag])  # drop purity flags: no CSE/deletion
            nswapped += 1
            verbose && println("  [gc_free] swap   %$i: $MemT -> arena")
        else
            nrejected += 1
            verbose && println("  [gc_free] reject %$i: may escape; stays on GC heap")
        end
    end

    ir.argtypes[1] = Tuple{}  # opaque-closure environment convention
    oc = Core.OpaqueClosure(ir; do_compile=true)
    return GCFreeKernel(oc, nswapped, nrejected)
end

end # module GCFreeTransform

using .GCFreeTransform

results = Pair{String,Bool}[]
function record!(name, ok)
    push!(results, name => ok)
    println(ok ? "  PASS: " : "  FAIL: ", name)
end

println("== Case A: plain-Julia kernel, allocation provably local -> arena ==")
function kernel(n::Int)
    v = Vector{Float64}(undef, n)
    for i in eachindex(v)
        v[i] = i
    end
    s = 0.0
    for i in eachindex(v)
        s += v[i]
    end
    return s
end

kernel_gcfree = gc_free(kernel, Tuple{Int})
record!("memorynew site was swapped to arena", kernel_gcfree.nswapped == 1)

let ok = kernel_gcfree(1000) == kernel(1000)
    record!("transformed kernel computes identical result", ok)
end

println("\n== Case B: escaping allocation is refused (safe fallback) ==")
function make_vector(n::Int)
    v = Vector{Float64}(undef, n)
    for i in eachindex(v)
        v[i] = i
    end
    return v  # escapes!
end

make_vector_gcfree = gc_free(make_vector, Tuple{Int})
record!("escaping allocation stays on the GC heap",
    make_vector_gcfree.nswapped == 0 && make_vector_gcfree.nrejected >= 1)
record!("untransformed fallback still computes correctly",
    make_vector_gcfree(10) == make_vector(10))

println("\n== Case C: escape via global is refused ==")
const SINK = Ref{Any}(nothing)
function stash_vector(n::Int)
    v = Vector{Float64}(undef, n)
    fill!(v, 1.0)
    SINK[] = v
    return n
end

stash_gcfree = try
    gc_free(stash_vector, Tuple{Int})
catch e
    e
end
# Either the borrow-check gate throws (it sees the escape/move) or the
# allocation-level analysis refuses the swap; both are safe outcomes.
record!("escape via global is not swapped",
    stash_gcfree isa BorrowCheckError ||
    (stash_gcfree isa GCFreeTransform.GCFreeKernel && stash_gcfree.nswapped == 0))

println("\n== Case D: allocation count and GC behavior ==")
function bench(f, n, iters)
    f(n)  # warmup
    GC.gc()
    g0 = Base.gc_num()
    t = @elapsed for _ in 1:iters
        f(n)
    end
    g1 = Base.gc_num()
    d = Base.GC_Diff(g1, g0)
    return (time=t, alloc_bytes=d.allocd, gc_time_ns=d.total_time, collections=d.pause)
end

let n = 100_000, iters = 500
    a1 = @allocated kernel(n)
    a2 = @allocated kernel_gcfree(n)
    println("  @allocated original   : ", a1, " bytes/call")
    println("  @allocated transformed: ", a2, " bytes/call")

    r1 = bench(kernel, n, iters)
    r2 = bench(kernel_gcfree, n, iters)
    println("  original   : $(r1.time)s, $(r1.alloc_bytes) GC bytes, $(r1.collections) collections, $(r1.gc_time_ns/1e9)s in GC")
    println("  transformed: $(r2.time)s, $(r2.alloc_bytes) GC bytes, $(r2.collections) collections, $(r2.gc_time_ns/1e9)s in GC")

    record!("transformed kernel GC-allocates <1% of original", a2 < a1 ÷ 100)
    record!("no GC collections in transformed loop", r2.collections == 0)
end

println("\n== Case E: results stay identical across arena reuse ==")
let ok = true
    for trial in 1:100
        n = rand(1:10_000)
        ok &= kernel_gcfree(n) == kernel(n)
    end
    record!("100 randomized trials agree with original", ok)
end

println("\n== Case F: per-site granularity -- local temp to arena, returned array stays on GC heap ==")
function mixed(n::Int)
    tmp = Vector{Float64}(undef, n)  # provably local -> arena
    out = Vector{Float64}(undef, n)  # returned -> must stay GC-managed
    for i in eachindex(tmp)
        tmp[i] = i
    end
    for i in eachindex(out)
        out[i] = 2 * tmp[n - i + 1]
    end
    return out
end

mixed_gcfree = gc_free(mixed, Tuple{Int})
record!("exactly the local temp was swapped",
    mixed_gcfree.nswapped == 1 && mixed_gcfree.nrejected == 1)

let n = 1000
    r1 = mixed_gcfree(n)
    r2 = mixed_gcfree(n)  # arena memory reused between calls
    ok = r1 == mixed(n) && r2 == mixed(n) && r1 !== r2
    record!("returned array is real GC memory, correct across arena reuse", ok)
    a1 = @allocated mixed(n)
    a2 = @allocated mixed_gcfree(n)
    println("  @allocated original   : ", a1, " bytes/call")
    println("  @allocated transformed: ", a2, " bytes/call  (the returned array only)")
end

println("\n== Summary ==")
for (name, ok) in results
    println("  ", ok ? "PASS" : "FAIL", "  ", name)
end
exit(all(last, results) ? 0 : 1)
