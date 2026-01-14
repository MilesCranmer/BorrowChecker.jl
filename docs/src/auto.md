# `@auto` (IR Borrow Checker)

```@meta
CurrentModule = BorrowChecker
```

`@auto` is an experimental, compiler-IR-based borrow checker intended as a **development tripwire** for ordinary Julia code.
On function entry it borrow-checks the current specialization and caches the result so subsequent calls are fast.

!!! warning
    `@auto` is highly compiler-dependent. Expect false positives and false negatives.
    It is for testing/debugging, not a safety guarantee.

## Basic Usage

```julia
using BorrowChecker: @auto

@auto function f(x)
    y = x
    x[1] = 0          # may error if `y` can observe this mutation
    return y
end
```

On failure, `@auto` throws `BorrowChecker.Auto.BorrowCheckError` with best-effort source context.

## Options

Options are parsed by the macro and compiled into a `BorrowChecker.Auto.Config`.

### `scope`

Controls whether the checker recursively borrow-checks callees (call-graph traversal):

- `scope=:none`: disable `@auto` entirely (no IR borrow-checking).
- `scope=:function` (default): check only the annotated method.
- `scope=:module`: recursively check callees whose defining module matches the module where `@auto` is used.
- `scope=:user`: recursively check callees, but **ignore `Base`** (still allows `Core`).
- `scope=:all`: recursively check callees across all modules (very aggressive; expect more work/edge cases).

Example:

```julia
@auto scope=:module function outer(x)
    return inner(x)
end
```

### `max_summary_depth`

Limits recursive effect summarization depth used when the checker cannot directly resolve effects.

```julia
@auto max_summary_depth=4 function f(x)
    return g(x)
end
```

### `optimize_until`

Controls which compiler pass to stop at when fetching IR via `Base.code_ircode_by_type`.

```julia
@auto optimize_until="compact 1" function f(x)
    return g(x)
end
```

## Registry Overrides (advanced)

The checker uses a small registry of effect specs for non-overloadable primitives.
You can add or override specs with:

```julia
using BorrowChecker.Auto: register_effects!
```
