# Experiment 1: `@safe` as a compile-time verifier for GC-free (arena) allocation.
#
# Bumper.jl gives us arena allocation (`@no_escape` + `@alloc`) that completely
# bypasses the GC heap for array data. Its documented safety contract is
# "nothing allocated with `@alloc` may escape the `@no_escape` block" -- but
# Bumper can only check the *value of the block* at runtime; escapes through
# globals, fields, or outer locals are silent use-after-free. The question:
# can `BorrowChecker.@safe` (which runs at compile time of each
# specialization) act as the missing escape checker?
#
# Findings from the naive attempts (kept here for the record):
#
#   * With NO effect registrations, `@safe` conservatively flags Bumper's own
#     internals (`alloc!` mutating the buffer while the checkpoint aliases
#     it), so *correct* arena code fails to check. Sound but useless.
#   * With blanket "Bumper internals are pure" registrations, correct code
#     passes -- but the escape detection disappears with the false positives,
#     because the original catches came from the same conservative aliasing.
#     Precise but unsound.
#
# The fix is to make the arena *lifetime* visible to the checker. The shim
# below expands `@checked_no_escape` like Bumper's `@no_escape`, but emits an
# explicit `release!(cp, x)` marker for every `@alloc` at block exit,
# registered as *consuming* `x`. Together with registering `UnsafeArray` as
# an owned resource type (its pointer IS the resource; by default isbits
# values are "Copy"-like and stores are never moves), `@safe` then enforces
# exactly Rust's rule: the allocation dies at block exit, and any use or
# store that outlives it is a compile-time BorrowCheckError.
#
# Run with: julia --project=experiments experiments/01_bumper_verifier.jl

import BorrowChecker
using BorrowChecker.Auto: BorrowCheckError

module BumperBorrowShim
# The integration shim (what a future BorrowCheckerBumperExt would contain).
using Bumper: Bumper, default_buffer, alloc!, checkpoint_save, checkpoint_restore!
using UnsafeArrays: UnsafeArray
using BorrowChecker.Auto: register_effects!, register_owned_type!

export @checked_no_escape

"""
    release!(cp, x)

Lifetime marker: does nothing at runtime (the actual reclamation is the bump
`checkpoint_restore!`), but is registered as *consuming* `x` so that `@safe`
treats the end of the `@checked_no_escape` block as the end of `x`'s
lifetime. Any later use of `x` (or an alias of it) is then a borrow-check
violation, and any earlier *store* of `x` (a move, since `UnsafeArray` is
registered as owned) followed by this marker is flagged too.
"""
@noinline function release!(cp, x)
    # `donotdelete` keeps inference from const-folding this call away before
    # the borrow checker's IR pass can see it.
    Base.donotdelete(x)
    return nothing
end

# Trusted axioms:
# * `alloc!` returns a FRESH disjoint region (Bumper's contract), so its result
#   must not be treated as aliasing the buffer -- otherwise writes through the
#   array spuriously conflict with the live checkpoint binding.
# * checkpoint bookkeeping only moves the bump offset; the lifetime discipline
#   it implies is exactly what `release!` expresses to the checker.
register_effects!(alloc!)
register_effects!(default_buffer)
register_effects!(checkpoint_save)
register_effects!(checkpoint_restore!)
register_effects!(release!; consumes=(3,))
register_owned_type!(UnsafeArray)

"""
    @checked_no_escape begin ... @alloc(T, dims...) ... end

Like `Bumper.@no_escape`, but borrow-checkable: every `@alloc` result is
released through [`release!`](@ref) at block exit, so `BorrowChecker.@safe`
can prove (at compile time of the specialization) that no allocation escapes.

Prototype limitations: allocations must be reachable on every path (no
conditional `@alloc`), nested `@no_escape` blocks and macros that expand to
`@alloc` are not handled, and the buffer is always `default_buffer()`.
"""
macro checked_no_escape(ex)
    @gensym buf
    allocs = Symbol[]

    # Rewrite `var = @alloc(T, dims...)` to `var = alloc!(buf, T, dims...)`,
    # recording `var` so it can be released at block exit. The `@alloc` may be
    # wrapped (e.g. an enclosing `@safe` instruments assignments with
    # `__bc_bind__` before we expand), so we look for it anywhere in the RHS
    # of an assignment. We deliberately do NOT introduce a hidden temporary
    # binding: a second live binding of the same allocation is (correctly!)
    # treated by the checker as aliasing, and writes through the user's
    # variable would then be flagged.
    function convert_allocs(e, found::Base.RefValue{Bool})
        e isa Expr || return e
        if e.head === :macrocall && e.args[1] === Symbol("@alloc")
            found[] = true
            args = map(a -> convert_allocs(a, found), e.args[3:end])
            return Expr(:call, alloc!, buf, args...)
        end
        return Expr(e.head, map(a -> convert_allocs(a, found), e.args)...)
    end

    rewrite(e) = e
    function rewrite(e::Expr)
        if e.head === :(=) && length(e.args) == 2 && e.args[1] isa Symbol
            found = Ref(false)
            rhs = convert_allocs(e.args[2], found)
            found[] && push!(allocs, e.args[1])
            return Expr(:(=), e.args[1], found[] ? rhs : rewrite(e.args[2]))
        elseif e.head === :macrocall && e.args[1] === Symbol("@alloc")
            error("@checked_no_escape (prototype) requires the `var = @alloc(...)` form")
        end
        return Expr(e.head, map(rewrite, e.args)...)
    end

    body = rewrite(ex)
    releases = [:($release!(cp, $(esc(v)))) for v in allocs]
    return quote
        $(esc(buf)) = $default_buffer()
        local cp = $checkpoint_save($(esc(buf)))
        local res = $(esc(body))
        $(releases...)
        $checkpoint_restore!(cp)
        res
    end
end

end # module BumperBorrowShim

using .BumperBorrowShim
using Bumper: @no_escape, @alloc  # raw Bumper, for the "unchecked" comparison

results = Pair{String,Bool}[]
function record!(name, ok)
    push!(results, name => ok)
    println(ok ? "  PASS: " : "  FAIL: ", name)
end

println("== Case A: correct arena usage (should borrow-check cleanly) ==")
BorrowChecker.@safe function sum_squares_arena(n::Int)
    s = 0.0
    @checked_no_escape begin
        x = @alloc(Float64, n)
        for i in 1:n
            x[i] = i
        end
        for i in 1:n
            s += x[i]^2
        end
        nothing
    end
    return s
end

let ok = try
        sum_squares_arena(10) == sum(i -> float(i)^2, 1:10)
    catch e
        showerror(stdout, e)
        println()
        false
    end
    record!("correct arena code passes @safe and computes correctly", ok)
end

println("\n== Case B: arena array leaks out of the block via an outer local + return ==")
# A genuine use-after-free: after the block, the bump offset is reset and the
# memory is silently reused by the next allocation.
BorrowChecker.@safe function leak_arena_return(n::Int)
    local x
    @checked_no_escape begin
        x = @alloc(Float64, n)
        fill!(x, 1.0)
        nothing
    end
    return x  # dangling: points into reclaimed arena memory
end

let ok = try
        leak_arena_return(10)
        false  # no error: the leak compiled & ran silently
    catch e
        e isa BorrowCheckError
    end
    record!("@safe rejects returning an @alloc'd array", ok)
end

println("\n== Case C: arena array leaks into a global ==")
const STASH = Ref{Any}(nothing)
BorrowChecker.@safe function leak_arena_global(n::Int)
    @checked_no_escape begin
        x = @alloc(Float64, n)
        fill!(x, 2.0)
        STASH[] = x  # escapes the arena scope
        nothing
    end
    return nothing
end

let ok = try
        leak_arena_global(10)
        false
    catch e
        e isa BorrowCheckError
    end
    record!("@safe rejects stashing an @alloc'd array in a global", ok)
end

println("\n== Case D: why this matters -- the same leak WITHOUT @safe is silent corruption ==")
# Bumper's own runtime tripwire only inspects the *value of the block*:
# escapes through a global (or any side channel) sail right past it.
const UNCHECKED_STASH = Ref{Any}(nothing)
function leak_unchecked(n::Int)
    @no_escape begin
        x = @alloc(Float64, n)
        fill!(x, 42.0)
        UNCHECKED_STASH[] = x
        nothing  # block value is not the array, so Bumper's check passes
    end
    return nothing
end
function clobber(n::Int)
    @no_escape begin
        y = @alloc(Float64, n)
        fill!(y, -1.0)
        sum(y)
    end
end

let
    leak_unchecked(10)
    dangling = UNCHECKED_STASH[]
    before = copy(dangling)
    clobber(10)
    after = copy(dangling)
    println("  dangling array before next @alloc: ", before[1:3])
    println("  dangling array after  next @alloc: ", after[1:3])
    record!("unchecked leak silently corrupts (demonstrating the bug class)", before != after)
end

println("\n== Case E: the GC payoff -- arena loop vs Vector loop ==")
function work_vector(n)
    v = Vector{Float64}(undef, n)
    for i in 1:n
        v[i] = i
    end
    s = 0.0
    for i in 1:n
        s += v[i]
    end
    return s
end

BorrowChecker.@safe function work_arena(n)
    s = 0.0
    @checked_no_escape begin
        v = @alloc(Float64, n)
        for i in 1:n
            v[i] = i
        end
        for i in 1:n
            s += v[i]
        end
        nothing
    end
    return s
end

function bench(f, n, iters)
    f(n)  # warmup / trigger @safe check + compile
    GC.gc()
    g0 = Base.gc_num()
    t = @elapsed for _ in 1:iters
        f(n)
    end
    g1 = Base.gc_num()
    d = Base.GC_Diff(g1, g0)
    return (time=t, alloc_bytes=d.allocd, gc_time_ns=d.total_time, collections=d.pause)
end

let n = 100_000, iters = 200
    rv = bench(work_vector, n, iters)
    ra = bench(work_arena, n, iters)
    println("  Vector : $(rv.time)s, $(rv.alloc_bytes) GC bytes, $(rv.collections) collections, $(rv.gc_time_ns/1e9)s in GC")
    println("  Arena  : $(ra.time)s, $(ra.alloc_bytes) GC bytes, $(ra.collections) collections, $(ra.gc_time_ns/1e9)s in GC")
    record!("arena version allocates <1% of the GC bytes of the Vector version",
        ra.alloc_bytes < rv.alloc_bytes ÷ 100)
end

println("\n== Summary ==")
for (name, ok) in results
    println("  ", ok ? "PASS" : "FAIL", "  ", name)
end
exit(all(last, results) ? 0 : 1)
