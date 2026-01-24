# `@safe` (IR Borrow Checker)

```@meta
CurrentModule = BorrowChecker
```

`@safe` is an experimental, compiler-IR-based borrow checker intended as a **development tripwire** for ordinary Julia code.
On function entry it borrow-checks the current specialization and caches the result so subsequent calls are fast.
The cache key includes the *active `@safe` options* (so e.g. a later call with `scope=:module` will not be skipped just because `scope=:function` previously checked the same specialization).

!!! warning
    `@safe` is highly compiler-dependent. Expect false positives and false negatives.
    It is for testing/debugging, not a safety guarantee.

## Basic Usage

```julia
using BorrowChecker: @safe

@safe function f(x)
    y = x
    x[1] = 0          # may error if `y` can observe this mutation
    return y
end
```

On failure, `@safe` throws `BorrowChecker.Auto.BorrowCheckError` with best-effort source context.

## Options

Options are parsed by the macro and compiled into a `BorrowChecker.Auto.Config`.

### `scope`

Controls whether the checker recursively borrow-checks callees (call-graph traversal):

- `scope=:none`: disable `@safe` entirely (no IR borrow-checking).
- `scope=:function` (default): check only the annotated method.
- `scope=:module`: recursively check callees whose defining module matches the module where `@safe` is used.
- `scope=:user`: recursively check callees, but **ignore `Core` and `Base`** (including their submodules).
- `scope=:all`: recursively check callees across all modules (very aggressive; expect more work/edge cases).

!!! note
    For `scope=:module` / `scope=:user`, callees are filtered by the **defining module of the resolved method** (so user-defined extensions of `Base` functions are still treated as “in-module” when appropriate).

Example:

```julia
@safe scope=:module function outer(x)
    return inner(x)
end
```

### `max_summary_depth`

Limits recursive effect summarization depth used when the checker cannot directly resolve effects.

```julia
@safe max_summary_depth=4 function f(x)
    return g(x)
end
```

### `optimize_until`

Controls which compiler pass to stop at when fetching IR via `Base.code_ircode_by_type`.

```julia
@safe optimize_until="compact 1" function f(x)
    return g(x)
end
```

Pass names vary across Julia versions; `@safe` normalizes common spellings like `"compact 1"` / `"compact_1"` when possible.

### `debug`

Enable debug logging (best-effort) to a JSONL file:

```julia
@safe debug=true function f(x)
    return g(x)
end
```

The output path is controlled by the `BORROWCHECKER_AUTO_DEBUG_PATH` environment variable (otherwise a file in `tempdir()` is used).
If `BORROWCHECKER_AUTO_DEBUG_PATH` is not set, `@safe debug=true` will emit a warning telling you where it is writing the file.

### `debug_callee_depth`

When `debug=true`, controls how deep in the recursive effect summarizer `@safe` also dumps IR (0 = only the entrypoint specialization).

## Registry Overrides (advanced)

The checker uses a small registry of effect specs for non-overloadable primitives.
You can add or override specs with:

```julia
using BorrowChecker.Auto: register_effects!
```
