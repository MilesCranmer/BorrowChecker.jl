# Experiments: avoiding the GC with BorrowChecker.jl

Two experiments exploring the idea that `@safe`'s compile-time
ownership/escape analysis provides exactly what manual memory management
lacks in Julia: a *proof* of where a value dies. The GC exists because Julia
doesn't know when objects die; a borrow checker is a machine for knowing
exactly that.

Both experiments run on Julia 1.12 with the `experiments/` project:

```sh
julia --project=experiments experiments/01_bumper_verifier.jl
julia --project=experiments experiments/02_gc_free_transform.jl
```

## Experiment 1: `@safe` as a verifier for arena allocation

[`01_bumper_verifier.jl`](01_bumper_verifier.jl)

[Bumper.jl](https://github.com/MasonProtter/Bumper.jl) provides bump/arena
allocation (`@no_escape` + `@alloc`) whose array data never touches the GC
heap. Its safety contract — *nothing may escape the block* — is enforced
only by a runtime check on the block's value; escapes through globals,
fields, or outer locals are silent use-after-free (demonstrated in Case D).

The experiment builds a small shim (`@checked_no_escape`) that makes the
arena lifetime visible to `BorrowChecker.@safe`:

1. **Effect axioms** for Bumper's API (`register_effects!`): `alloc!`
   returns a fresh disjoint region; checkpoint bookkeeping is effect-free.
   Without these, the checker conservatively flags *correct* arena code
   (sound but useless). With only these, it misses real escapes (precise
   but unsound) — the original catches came from the same conservative
   aliasing as the false positives.
2. **A consume marker**: the macro emits `release!(cp, x)` for every
   `@alloc` at block exit, registered with `consumes=(3,)`. The end of the
   block becomes the end of the allocation's lifetime in the checker's
   move semantics. (`Base.donotdelete` keeps inference from const-folding
   the marker away before the IR pass sees it.)
3. **`register_owned_type!(UnsafeArray)`** — a new extension hook added to
   `BorrowChecker.Auto` by this branch. By default `isbits` values are
   "Copy"-like, so storing one is never a move; that's wrong for
   pointer-backed containers where the pointer *is* the resource.

Results (all checked in the script):

| case | outcome |
|---|---|
| correct arena kernel | borrow-checks cleanly, computes correctly |
| arena array returned from block | compile-time `BorrowCheckError` |
| arena array stashed in a global | compile-time `BorrowCheckError` (invisible to Bumper's own check) |
| same leak unchecked | silent data corruption (the bug class being prevented) |
| arena vs `Vector` loop (100k floats × 200) | **160 MB GC traffic, 3 collections → 0 bytes, 0 collections, ~2.6× faster** |

## Experiment 2: borrow-check-gated IR transformation

[`02_gc_free_transform.jl`](02_gc_free_transform.jl)

The inverse direction: the user writes *plain Julia* (`Vector{Float64}(undef, n)`
etc.), and a compile-time pass moves provably-local allocations off the GC
heap automatically. Pipeline:

1. **Gate**: `Auto.check_signature` runs the `@safe` borrow check on the
   specialization; failures abort the transform.
2. Fetch fully optimized post-inlining `IRCode`
   (`Base.code_ircode_by_type`). On Julia 1.12, `Vector{T}(undef, n)`
   appears as a single `Core.memorynew(Memory{T}, n)` builtin call.
3. **Escape analysis per allocation site**: compute the transitive
   "derived" set (the `%new` Vector wrapper, `memoryrefnew`s, `getfield`s,
   phis — filtered by whether the value's *type* can carry the pointer),
   then require every use of every member to be on a whitelist of
   non-escaping operations. `ReturnNode`s, unknown calls, and stores where
   a derived value is the *stored value* all reject the site.
4. **Rewrite** proven sites to `arena_memorynew` (bump-allocate from
   Bumper's buffer, `unsafe_wrap` a real `Memory{T}` around the pointer —
   only the ~48-byte header stays on the GC heap), and compile with
   `Core.OpaqueClosure(ir)`.
5. **Deterministic drop**: the wrapper saves/restores an arena checkpoint
   around the call — the ownership proof tells us where the free goes.

The polarity is the safe one: anything unproven stays on the GC heap, so a
conservative analysis costs performance, never correctness.

Results (all checked in the script):

| case | outcome |
|---|---|
| local kernel (fill + reduce, 100k floats) | allocation swapped: **800,040 → 48 bytes/call**; 400 MB GC traffic, 20 collections → 24 KB, 0 collections; ~2.1× faster |
| function returning its array | site refused, falls back to GC, still correct |
| escape via global | site refused |
| mixed function (local temp + returned array) | exactly the temp is swapped; returned array survives arena reuse |
| 100 randomized trials | bit-identical to the original |

### Division of labor observed

The `@safe` gate and the allocation-site analysis catch different things:
`stash_vector` (store to global, never used again) is *legal* under Rust
move semantics — `@safe` correctly passes it — but the allocation must
still stay GC-managed, which the site analysis enforces. Conversely the
gate rejects aliasing patterns the site whitelist would not understand.

### Known prototype caveats (documented in the scripts)

- Bounds-error paths store the array in the thrown `BoundsError`; throwing
  calls are whitelisted, so a caller that catches and reads `err.a` sees
  freed arena memory. Closable via `@inbounds` kernels or by rejecting
  functions with reachable boundserror paths.
- Only `isbits` element types are eligible (the GC cannot trace references
  stored in foreign memory) — the same restriction Bumper has.
- `@checked_no_escape` requires the `var = @alloc(...)` form, straight-line
  allocation (no conditional `@alloc`), and the default buffer.
- The transform is per-function (post-inlining); callee allocations would
  need whole-call-graph compilation under a custom `AbstractInterpreter`
  (the `BCInterp` in `src/auto/generated.jl` is the natural seed for this).
- The effect registrations for Bumper internals are trusted axioms.

### Takeaway

Both directions work end-to-end. The borrow checker doesn't *remove* the
GC — it supplies the lifetime proofs that let allocations opt out of it,
with the GC as the always-correct fallback. Experiment 1 is close to
shippable as a package extension (`BorrowCheckerBumperExt`); Experiment 2
is a research prototype demonstrating that `@safe`'s machinery stages at
exactly the right place in compilation to do real allocation rewriting.
