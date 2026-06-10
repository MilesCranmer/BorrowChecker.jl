# BorrowChecker.jl claim verification — experiment report

**Date:** 2026-06-10
**Julia:** 1.12.5 (conda-forge build, linux x86_64) — the official julialang.org
binaries were unreachable from this container's network policy; the conda-forge
`julia 1.12.5` package was used instead. Version is inside the `@safe` support
range (1.12 ≤ v < 1.15).
**Machine:** 4-core x86_64 Linux container (timings below are from this machine,
idle, `julia -t 1` unless stated).
**Baseline:** `Pkg.test()` on commit `935aed1` passes (exit 0).
**Scripts:** one file per experiment in `experiments/` (run each in a fresh
process). `setup_patched.sh` builds the counter-instrumented checkout used by
E11/E14.

## Summary table

| #   | Claim                                  | Verdict                                  | Key number / output |
|-----|----------------------------------------|------------------------------------------|---------------------|
| E1  | getindex no-alias false negative       | **CONFIRMED**                            | E1a no error; E1b control throws `BorrowCheckError` ("value is aliased by another live binding") |
| E2  | arg aliasing `f(v, v)` invisible       | **CONFIRMED**                            | no error |
| E3  | global double-load invisible           | **CONFIRMED**                            | no error |
| E4  | foreigncall escape missed              | **CONFIRMED**                            | ccall-retains case: no error; Dict-escape control throws |
| E5  | scope=:module cache poisoning          | **CONFIRMED (internal API)** / not reachable via `@safe` macro | stale pass masks violation at same world; control fails |
| E6  | PhiCNode assert reachable              | **CONFIRMED (strongly)**                 | 183/200 fuzz cases assert; 5-line minimal repro |
| E7  | summary cache race                     | **NOT REPRODUCED**                       | 0 asserts, 0 spurious errors in 2400+ concurrent checks (`-t 8`) |
| E8  | world-bump full invalidation           | **FALSIFIED**                            | t_after_bump/t_warm ≈ 0.7–2.5x (µs both); cold ≈ 0.52 s |
| E9  | per-call prologue cost                 | **FALSIFIED**                            | safe 2.08 ns vs raw 2.37 ns (−0.3 ns "overhead") |
| E10 | BitSet allocs dominate check_ir        | **FALSIFIED**                            | Julia inference = 99.1% of bytes; all of BorrowChecker = 0.9%; checker.jl BitSet lines ≈ 15 KB total |
| E11 | is_tracked_type uncached cost          | **FALSIFIED (no payoff)**                | 354–720 calls/check, repeat ratio 6–17x, ~1.5 µs/call ⇒ ≲1 ms of a 0.5–3 s check |
| E12 | cold latency + budget false positives  | **CONFIRMED (both)**                     | 57.7 s / 16.6 s / 12.7 s cold; 3/3 false positives; 72/327 summaries over budget |
| E13 | `__bc_bind__` body tax                 | **FALSIFIED**                            | slowdown 1.000x; 0 bind/barrier remnants in typed+LLVM IR |
| E14 | known-effects lock in hot path         | **PARTIAL** (lock real, cost negligible; but checks don't parallelize) | 28.6 ns/call × ~1600 calls/check ≈ 46 µs; `-t 8` parallel checking 0.68x *slower* than sequential |
| E15 | unbounded cache growth                 | **CONFIRMED (bounded severity)**         | 29 summary entries/function, no eviction; ~12 MB per 1000 checks cache-attributable (134 MB total incl. compiled code) |
| E16 | overlay atomic/Lifetime overhead       | **CONFIRMED**                            | OwnedMut `Ref` access 2.25x raw; seq_cst→monotonic patch: 1.62x; `@ref` churn ≈ 250 ns + ~1.9 allocs per borrow |

## Part A: false negatives (all confirmed)

**E1 — array `getindex` creates no alias.** `f1(outer) = (a = outer[1]; b = outer[1];
push!(a, 2); return b)` passes silently. The struct-field control `g1` (same shape
through `w.v`, where `getfield` is registered with `ret_aliases=(2,)`) throws
`cannot perform write: value is aliased by another live binding`. The gap is exactly
as claimed: `Core.memoryrefget` is registered with empty `ret_aliases`
(`src/auto/defs.jl:219`), so extracted elements never alias their container.

**E2 — `h2(v, v)` argument aliasing.** No error. Distinct arguments are assumed
disjoint.

**E3 — two loads of the same global.** No error. Each global load is a fresh
untracked origin.

**E4 — foreigncall retention.** A `ccall` to a C function that stashes its argument
in a C global, followed by `push!` on the same array, passes silently. The
Julia-level control (escape into a `Dict` then mutate) throws. Unknown foreigncalls
are not modeled as consumes.

## Part B: bugs

**E5 — `scope=:module` cache poisoning.** Two protocol corrections were needed:

1. The suggested violation (`y = x; push!(x, 3); return y`) is invisible inside an
   *uninstrumented* callee — without `@safe`'s `__bc_bind__` the alias collapses to
   one SSA value. A Dict-escape-then-mutate violation was used instead (verified
   detectable: fresh check of `helper` rooted at `M5` fails).
2. On Julia 1.12 every new top-level global binding bumps the world counter
   (world-partitioned bindings), and both caches require an exact world match, so a
   naive top-level script accidentally misses the cache between probes. The probe
   sequence must run inside one function invocation (stable world) — which is also
   the realistic scenario.

With those fixes, the internal-API sequence reproduces exactly as claimed
(`e05_cache_poisoning.jl`): fresh check rooted at `M5` **fails**; fresh check rooted
at `Other5` **passes**; the un-cleared re-check rooted at `M5` **passes** (stale
cache hit masks the violation); a cleared control **fails** again.
`_checked_cache_sig` (`src/auto/frontend.jl:8`) does drop `root_module` and
`__bc_assert_safe__` trusts it.

However, the **user-facing `@safe` macro path is structurally protected** (e05b,
e05c): the macro does not call `__bc_assert_safe__` at runtime — it emits a
`@generated` prologue (`_generated_assert_safe`, `src/auto/generated.jl`) whose
`Config` derives `root_module` from the *method's own module* via
`_methods_by_ftype`, and callee recursion only descends into callees whose
method-module `===` root. A given tt is therefore essentially always checked under
one root through the macro. Verdict: real bug at the `Auto.__bc_assert_safe__` /
`Auto.Config` API level; not reachable through `@safe` alone in our attempts.

*Side finding (e05c):* with `scope=:module`, a method added to `MX`'s function from
another module `A` (extension form `@safe scope=:module function MX.helper() ... end`)
belongs to module `A`, so an `MX`-rooted wrapper that calls it is **silently not
recursed into** (`wrapper` passes fresh even though `helper → g` violates). A
scope-design false negative independent of caching.

**E6 — PhiCNode assertion fires on legal IR. Strongly confirmed.**
The assertion at `src/auto/checker.jl:47` is
`@assert length(vals) != length(preds)` — it *fires* when the lengths are equal,
which is ordinary, legal IR. The three handwritten probes pass, but the seeded
fuzzer (`e06b`, 200 random try/catch/finally functions) hits
`AssertionError: Unexpected IR: PhiCNode.values length unexpectedly matches
predecessor count.` in **183/200** cases (10 BorrowCheckErrors, 7 clean). Minimal
reproducer:

```julia
BorrowChecker.@safe function n2()
    a = [1, 2]
    try
        push!(a, 1)
    catch e
        a = copy(a)
    finally
        sum(a)
    end
    return a
end
n2()  # AssertionError, not a BorrowCheckError
```

*Side finding:* plain `try push!(a, 1) finally sum(a) end; return a` (no rebinding)
is a **false positive** `BorrowCheckError` — semantically fine code rejected.

**E7 — summary-cache race. Not reproduced.**
Protocol correction: the suggested inner `(push!(x,1); sort!(x); nothing)` is a
false positive even at `-t 1` (`sort!` fails to summarize ⇒ unknown call ⇒
consume-all), so it cannot detect threading-induced errors. With a clean two-level
chain that passes at `-t 1`: 100 trials × 8 concurrent tasks at `-t 8`, repeated 3
runs (2400 calls) plus a direct `scope=:user` stress of `__bc_assert_safe__` on 8
distinct tts × 30 trials — **0 assertion errors, 0 spurious BorrowCheckErrors**.
Caveat: 4 physical cores; and `__bc_assert_safe__` holds the `CHECKED_CACHE` lock
across the whole check, which serializes the supposed racers (see E14).

## Part C: performance

**E8 — world-bump invalidation. Falsified.** 5 repetitions: cold 0.52–35 s (the
35 s is one-time checker-infrastructure compilation in rep 1), warm 1–12 µs,
after an unrelated method definition 2.5–3.8 µs (ratio to warm 0.72–2.5x; ratio to
cold ~5×10⁻⁶). The `@generated` prologue compiles to `return nothing` with explicit
method edges, so invalidation is edge-based, not world-exact. A follow-up probe for
the opposite failure (stale pass after a callee is redefined with a violation)
also behaved correctly: the redefinition re-triggered the check and it failed.

**E9 — per-call prologue. Falsified.** `@safe` 2.077 ns vs raw 2.368 ns minimum
(ratio 0.88; the claimed runtime tt construction / dict lookup does not exist on
the macro path — see E8 mechanism).

**E10 — BitSet allocations. Falsified.** Whole-stack attribution of an
alloc-profiled first check of a 500-statement function (sample_rate=0.05; rate 1
OOMs a 4 GB container): **Julia Compiler (inference) 99.1%** of bytes,
**all BorrowChecker code 0.9%**; the biggest BorrowChecker line is ~10 KB in
`summaries.jl`, and the `live_during = BitSet(live)` neighborhood
(`checker.jl:151–157`) totals ~15 KB. A scratch-set patch has no headroom; not
pursued. First-check wall time scales mildly superlinearly: 250 stmts 1.58 s,
500 → 2.99 s, 1000 → 6.95 s, 2000 → 19.0 s (~n^1.2, 3–10 ms/stmt).

**E11 — `is_tracked_type` memoization. No payoff.** Counter-instrumented checkout:
one E8-style first check makes 354 `is_tracked_type` + 18 `is_owned_type` calls
(repeat ratio 6.0x; top args `Int64`×81, `Any`×60, `Vector{Int64}`×41); a
500-statement check makes 720 + 1 calls (repeat ratio 16.8x). At ~1.5 µs per
uncached deep-struct call this is ≲1 ms of a 0.5–3 s check (<0.1%). An `IdDict`
memo would save nothing measurable; not implemented, by the data.

**E12 — cold latency + false positives. Both confirmed.** Cold first-check on
three ordinary functions: **57.7 s, 16.6 s, 12.7 s** — and **all three are false
positives**. Every violation message is the unknown-call degradation
(`value escapes/consumed by unknown call; it (or an alias) is used later`) on
`String` `*`, `Dict` `getindex`, `join`, `print(io, ...)`, `get!`. With
`debug=true`, the JSONL shows **72 of 327** callee summaries `over_budget:true`
(22%), confirming budget exhaustion as a contributor.

**E13 — `__bc_bind__` body tax. Falsified.** The macro does insert `__bc_bind__`
(visible in macroexpansion), but the binding-heavy loop benchmark is **1.000x**
(11.79 µs both), and the optimized typed IR and LLVM IR of `ksafe` contain **zero**
`__bc_bind__`/`inferencebarrier` remnants and zero call instructions in the loop.
The `@generated` `__bc_bind__` (defs.jl:44) inlines away completely after the check.

**E14 — known-effects lock. Partially confirmed, wrong bottleneck.**
`_known_effects_get(push!)` = **28.6 ns** (lock acquire per call, >20 ns as
claimed); ~1588 calls per 500-statement check (≈3.2/statement — "per-statement-ish"
as claimed). But that totals ≈46 µs of a 3 s check (~0.001%): not a hot path.
The real concurrency finding: first-checking 8 distinct functions on 8 threads is
**0.68x the sequential throughput** (8.4 s vs 5.7 s) — checking is fully serialized
(`__bc_assert_safe__` holds the `CHECKED_CACHE` lock across the entire check;
generated-function expansion serializes similarly) and contention adds overhead.

**E15 — unbounded cache growth. Confirmed, modest slope.** 5 rounds × 200 new
`@safe` functions: summary caches grow exactly linearly (5800 → 29000 entries,
29/function) with no eviction; `CHECKED_CACHE` stays empty on the macro path
(scope=:function ⇒ no callee recursion). Naive heap slope is 122 MB/1000 checks,
but clearing the caches and re-GCing recovers only **12 MB per 1000 checks** — the
rest is compiled code/method tables for the 1000 new functions themselves. So:
growth is real and unbounded, severity ≈12 KB/checked specialization.

**E16 — manual-overlay overhead. Confirmed.** `x[] = x[] + 1` loop through
`OwnedMut{Ref}`: **2.25x** raw `Ref` (2.65 vs 1.18 ns/iteration; per-access
validate with seq-cst loads, zero allocs). `is_moved` LLVM contains exactly one
`load atomic i8 ... seq_cst`. Patching all 8 `:sequentially_consistent` sites in
`src/types.jl` to `:monotonic` drops the ratio to **1.62x** even on x86 — i.e.
~40% of the per-access overhead is the memory ordering (expect more on ARM; not
measurable here). `@ref` churn: **~254 ns and ~1.9 allocs (~50 B) per
borrow+use**, essentially unchanged (241 ns) under monotonic — dominated by
Lifetime bookkeeping, not ordering.

## Protocol deviations / experiment-design notes

- Official Julia binaries and Pkg servers were blocked by the network policy;
  used conda-forge Julia 1.12.5 and the General registry via git from GitHub.
- E5: violation pattern and world-stability corrections described above; the
  originally specified probe is invalid on 1.12 as written.
- E6: the three scripted probes all pass; the conclusion rests on the (specified)
  fuzzer, which the protocol anticipated.
- E7/E14: replaced the `sort!`-containing workload, which is a single-threaded
  false positive and would have produced a vacuous "race" signal.
- E7 requested `-t 8` on an 8-core machine; this container has 4 cores
  (oversubscribed `-t 8` used). A negative result here is weaker than it would be
  on real 8-core hardware, but the lock structure (E14) makes a data race in
  summarization unlikely to be observable at all while `CHECKED_CACHE`'s lock
  spans the whole check.
- E10: `sample_rate=1` exhausts container memory; 0.05 used. First-frame
  attribution is dominated by allocator frames; whole-stack attribution reported.
- E11/E16 "patch and re-measure" sub-experiments: E16 done (monotonic patch);
  E11/E10 patches skipped because the measured ceiling (<0.1% / 0.9%) makes the
  result a foregone conclusion.
