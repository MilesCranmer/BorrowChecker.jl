<div align="center">

<img src="https://github.com/user-attachments/assets/b68b4d0e-7bec-4876-a39d-5edf3191a8d9" width="500">

# BorrowChecker.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://astroautomata.com/BorrowChecker.jl/dev)
[![Build Status](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://coveralls.io/repos/github/MilesCranmer/BorrowChecker.jl/badge.svg?branch=main)](https://coveralls.io/github/MilesCranmer/BorrowChecker.jl?branch=main)

</div>

This is an experimental package for emulating a runtime borrow checker in Julia, using a macro layer over regular code. This is built to mimic Rust's ownership, lifetime, and borrowing semantics. This tool is mainly to be used in development and testing to flag memory safety issues, and help you design safer code.

BorrowChecker.jl provides one layer:

**Automatic checking (`BorrowChecker.@safe`)**
- Drop-in for existing Julia code: wrap a function and BorrowChecker will run a best-effort borrow check when that method specialization executes.
- It does not change program behavior (except for throwing when it finds a violation).

In Julia, when you write `x = [1, 2, 3]`, the actual _object_ exists completely independently of the variable, and you can refer to it from as many variables as you want without issue:

```julia
x = [1, 2, 3]
y = x
println(length(x))
# 3
```

Once there are no more references to the object, the "garbage collector" will work to free the memory.

Rust is much different. For example, the equivalent code is **invalid** in Rust

```rust
let x = vec![1, 2, 3];
let y = x;
println!("{}", x.len());
// error[E0382]: borrow of moved value: `x`
```

Rust refuses to compile this code. Why? Because in Rust, objects (`vec![1, 2, 3]`) are _owned_ by variables. When you write `let y = x`, the ownership of `vec![1, 2, 3]` is _moved_ to `y`. Now `x` is no longer allowed to access it.

To fix this, we would either write

```rust
let y = x.clone();
// OR
let y = &x;
```

to either create a copy of the vector, or _borrow_ `x` using the `&` operator to create a reference. You can create as many references as you want, but there can only be one original object.

This "ownership" paradigm can help improve safety of code. Especially in complex, multithreaded codebases, it is easy to shoot yourself in the foot and modify objects which are "owned" (editable) by something else. Rust's ownership and lifetime model makes it so that you can _prove_ memory safety of code! Standard thread races are literally impossible. (Assuming you are not using `unsafe { ... }` to disable safety features, or the borrow checker itself has a bug, etc.)

In BorrowChecker.jl, we demonstrate an implementation of some of these ideas. The aim is to build a development layer that can help prevent a few classes of memory safety issues, without affecting runtime behavior of code.

## Automatic Checking: `BorrowChecker.@safe`

`BorrowChecker.@safe` automatically instruments a function by analyzing the compiler IR and runs a best-effort borrow check at runtime. This requires Julia ≥ 1.12.

> [!WARNING]
> This macro is highly experimental and compiler-dependent. There are likely bugs and false positives. It is intended for development and testing, and does not guarantee memory safety.

### Options

`@safe` supports a few options that are compiled into a `BorrowChecker.Auto.Config`:

- `scope` (default `:function`): whether to recursively borrow-check callees (`:none`, `:function`, `:module`, `:user`, `:all`).
- `max_summary_depth` (default `12`): recursion depth limit for effect summarization when effects cannot be directly resolved.
- `optimize_until` (default varies): which compiler pass to stop at when fetching IR (`Base.code_ircode_by_type`).

`scope` meanings:

- `:none`: disable `@safe` entirely.
- `:function`: check only the annotated method.
- `:module`: recursively check callees defined in the module where `@safe` is used.
- `:user`: recursively check callees, but ignore `Core` and `Base` (including their submodules).
- `:all`: recursively check callees across all modules (very aggressive).

The `@safe` checked-cache is keyed by specialization *and these options*, so checking a function once under `scope=:function` will not incorrectly skip a later recursive check under `scope=:module` / `:all`.

`@safe` is meant to be a *drop-in tripwire* for existing code:

- **Aliasing violations**: mutating a value while another live binding may observe that mutation.
- **Escapes / "moves"**: storing a mutable value somewhere that outlives the current scope (e.g. a global cache / a field / a container), then continuing to reference it locally.

This analyzes the compiler’s IR, so it can catch patterns that are "hidden" by lowering (keyword calls, closure captures, views, etc.). It is intentionally **best-effort**: when it cannot determine what a call does, it will be conservative (and may throw false positives). For regions where the checker is overly conservative, silence them with [`@unsafe`](@ref-opting-out) blocks.

### How it works

When you write:

```julia
BorrowChecker.@safe function f(args...)
    # ...
end
```

the macro rewrites the function so that:

1. **On entry**, it runs a borrow check for the *current method specialization* (e.g. `f(::Vector{Int})`), and caches the result (so future calls are faster).
2. The checker asks Julia for the function's **typed compiler IR** (the lowered form the compiler optimizes).
3. It walks that IR and tracks two key things:
   - Which bindings may refer to the **same mutable object** (aliasing).
   - Which operations **write** to a tracked object or cause it to **escape** (be treated like a move).
4. When it sees an operation that would be illegal under Rust-like rules (e.g. "write while aliased", or "use after escape"), it throws a `BorrowCheckError` with a source-level-ish diagnostic.

### Aliasing Detection

BorrowChecker.jl's `@safe` macro can detect when values are modified through aliased bindings, and throw an error:

```julia
julia> import BorrowChecker

julia> BorrowChecker.@safe function f()
           x = [1, 2, 3]
           y = x
           push!(x, 4)
           return y
       end
f (generic function with 1 method)

julia> f()  # errors
```

This will generate a helpful error pointing out the location of the borrow check violation, and the statement that violated the rule:

```
ERROR: BorrowCheckError for specialization Tuple{typeof(f)}

  method: f() @ Main REPL[7]:1

  [1] stmt#7: cannot perform write: value is aliased by another live binding      at REPL[7]:4
        2         x = [1, 2, 3]
        3         y = x
      > 4         push!(x, 4)
        5         return y
        6     end

      stmt: Main.push!(%5, 4)

```

To fix it, simply copy the value, which will avoid the error:

```julia
julia> BorrowChecker.@safe function f()
           x = [1, 2, 3]
           y = copy(x)
           push!(x, 4)
           return y
       end
f (generic function with 1 method)

julia> f()
3-element Vector{Int64}:
 1
 2
 3
```

### Escape Detection

Much like Rust's ownership model, BorrowChecker.jl's `@safe` macro attempts to infer when values escape their scope (moved/consumed) and throw an error if they are used afterwards.

```julia
julia> const CACHE = Dict()
Dict{Any, Any}()

julia> foo(x) = (CACHE[x] = 1; nothing)
foo (generic function with 1 method)

julia> BorrowChecker.@safe function bar()
           x = [1, 2]
           foo(x)
           return x
       end
bar (generic function with 1 method)

julia> bar()  # errors
```

This generates the following error:

```
ERROR: BorrowCheckError for specialization Tuple{typeof(bar)}

  method: bar() @ Main REPL[13]:1

  [1] stmt#6: value escapes/consumed by unknown call; it (or an alias) is used later      at REPL[13]:3
        1     BorrowChecker.@safe function bar()
        2         x = [1, 2]
      > 3         foo(x)
        4         return x
        5     end

      stmt: Main.foo(%5)
```

Why is this an error? Because `x` was stored as a key in the cache, but is _mutable externally_. Furthermore, it is returned by `bar`! This is a violation of borrowing rules. Once the value gets stored in the cache, its ownership is _transferred_ to the cache, and is no longer accessible by `bar`. So this example is illegal.

How can we fix it? We have two options. The first is we can copy the value before storing it:

```julia
julia> BorrowChecker.@safe function bar()
           x = [1, 2]
           foo(copy(x))
           return x
       end
bar (generic function with 1 method)

julia> bar()  # ok
```

We no longer have access to the object created by `copy(x)`, so the borrow check passes.
Alternatively, we can use immutable objects, which are safe to pass around:

```julia
julia> BorrowChecker.@safe function bar()
           x = (1, 2)
           foo(x)
           return x
       end
bar (generic function with 1 method)

julia> bar()  # ok
```

### More `@safe` examples

<details>
<summary><code>@safe</code> analyzes the entire callstack</summary>

BorrowChecker doesn't rely on naming conventions, such as the presence of `!` in the function name. It tries to infer effects from IR:

```julia
julia> h(x) = (push!(x, 1); nothing)  # no "!" in the name
h (generic function with 1 method)

julia> BorrowChecker.@safe function demo()
           x = [1, 2, 3]
           y = x
           h(x)
           return y
       end
demo (generic function with 1 method)

julia> demo()  # errors
```
</details>

<details>
<summary>Keyword arguments are handled (the checker sees lowered <code>kwcall</code> IR)</summary>

Keyword calls get lowered into a `NamedTuple` + `Core.kwcall(...)`. `@safe` analyzes the lowered IR, so aliasing via keyword arguments is still visible:

```julia
julia> f(; x, y) = (push!(x, 1); push!(y, 1); x .+ y)
f (generic function with 1 method)

julia> BorrowChecker.@safe function kw_demo()
           x = [1, 2, 3]
           y = x
           return sum(f(; x=x, y=y))
       end
kw_demo (generic function with 1 method)

julia> kw_demo()  # errors
```
</details>

<details>
<summary>Aliasing isn't only <code>y = x</code>: views can alias too</summary>

```julia
julia> BorrowChecker.@safe function view_demo()
           x = [1, 2, 3, 4]
           y = view(x, 1:2)  # aliases x
           push!(x, 9)
           return collect(y)
       end
view_demo (generic function with 1 method)

julia> view_demo()  # errors
```
</details>

<details>
<summary>Closures are analyzed too</summary>

```julia
julia> BorrowChecker.@safe function closure_demo()
           x = [1, 2, 3]
           y = x
           f = () -> (push!(x, 9); nothing)
           f()
           return y
       end
closure_demo (generic function with 1 method)

julia> closure_demo()  # errors
```

Read-only captures are typically fine.
</details>


## Opting out: `@unsafe` blocks

`@unsafe` is an escape hatch analogous to `@inbounds`: inside the block, the
checker skips aliasing and escape validation entirely, and effects inside it
(writes, consumes, new aliases) do not propagate outward into the surrounding
analysis. You take responsibility for upholding the borrow rules yourself.

```julia
julia> BorrowChecker.@safe function add_halves!(a::Vector{Float64})
           n = length(a) ÷ 2
           BorrowChecker.@unsafe begin
               left = @view a[1:n]
               right = @view a[(n + 1):(2n)]
               left .+= right
           end
           return a
       end
```

`@unsafe` also works on a single expression, e.g. to silence one unanalyzable
call in an otherwise checked function:

```julia
julia> BorrowChecker.@safe w_gradient(f, x) =
           BorrowChecker.@unsafe gradient(f, backend, x)
```

## Disabling BorrowChecker

Set `borrow_checker = false` in your `LocalPreferences.toml` (via
Preferences.jl) to make every macro pass through untouched, or call
`disable_by_default!(@__MODULE__)` at the top of a module to ship it disabled
and enable checking in your test suite.
