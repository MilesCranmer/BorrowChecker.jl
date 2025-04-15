<div align="center">

<img src="https://github.com/user-attachments/assets/b68b4d0e-7bec-4876-a39d-5edf3191a8d9" width="500">

# BorrowChecker.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://astroautomata.com/BorrowChecker.jl/dev)
[![Build Status](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://coveralls.io/repos/github/MilesCranmer/BorrowChecker.jl/badge.svg?branch=main)](https://coveralls.io/github/MilesCranmer/BorrowChecker.jl?branch=main)

</div>

This is an experimental package for emulating a runtime borrow checker in Julia, using a macro layer over regular code. This is built to mimic Rust's ownership, lifetime, and borrowing semantics. This tool is mainly to be used in development and testing to flag memory safety issues, and help you design safer code.

> [!WARNING]
> BorrowChecker.jl does not guarantee memory safety. This library emulates aspects of Rust's ownership model, but it does not do this at a compiler level. Furthermore, BorrowChecker.jl heavily relies on the user's cooperation, and will not prevent you from misusing it, or from mixing it with regular Julia code.

## Usage

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

The above example, with BorrowChecker.jl, would look like this:

```julia
using BorrowChecker

@own x = [1, 2, 3]
@own y = x
println(length(x))
# ERROR: Cannot use x: value has been moved
```

You see, the `@own` operation has _bound_ the variable `x` with the object `[1, 2, 3]`. The second operation then moves the object to `y`, and flips the `.moved` flag on `x` so it can no longer be used by regular operations.

The equivalent fixes would respectively be:

```julia
@clone y = x
# OR
@lifetime a begin
    @ref ~a y = x
    #= operations on reference =#
end
```

Note that BorrowChecker.jl does not prevent you from cheating the system and using `y = x` (_however, the library does try to flag such mistakes by recording symbols used in the macro_). To use this library, you will need to _buy in_ to the system to get the most out of it. But the good news is that you can introduce it in a library gradually:  add `@own`, `@move`, etc., inside a single function, and call `@take!` when passing objects to external functions. And for convenience, a variety of standard library functions will automatically forward operations on the underlying objects.

### Example: Preventing Thread Races

BorrowChecker.jl helps prevent data races by enforcing borrowing rules.

Let's mock up a simple scenario where two threads modify the same array concurrently:

```julia
data = [1, 2, 3]

modify!(x, i) = (sleep(rand()+0.1); push!(x, i))

t1 = Threads.@spawn modify!(data, 4)
t2 = Threads.@spawn modify!(data, 5)

fetch(t1); fetch(t2)
```

This has a silent race condition, and the result will be non-deterministic.

Now, let's see what happens if we had used BorrowChecker:

```julia
@own :mut data = [1, 2, 3]

t1 = Threads.@spawn @bc modify!(@mut(data), 4)
t2 = Threads.@spawn @bc modify!(@mut(data), 5)
```

Now, when you attempt to fetch the tasks, you will get this error:

```text
nested task error: Cannot create mutable reference: `data` is already mutably borrowed
```

This is because in BorrowChecker.jl's ownership model, similar to Rust, an owned object follows strict borrowing rules to prevent data races and ensure safety.
(Though, in practice, you should use `BorrowChecker.@spawn` instead of `Threads.@spawn`, so that it validates captured variables.)

## Ownership Rules

At any given time, an object managed by BorrowChecker.jl can only be accessed in one of the following states:

1. **Direct Ownership:**
    - The object is accessed directly via its owning variable.
    - No active references (`Borrowed` or `BorrowedMut`) exist.
    - In this state, ownership can be transferred (moved) to another variable, after which the original variable becomes inaccessible. The object can also be mutated if it was declared as mutable (`@own :mut ...`).

2. **Immutable Borrows:**
    - One or more immutable references (`Borrowed`) to the object exist.
    - While any immutable reference is active:
        - The original owning variable _cannot_ be mutated directly.
        - Ownership _cannot_ be moved.
        - No mutable references (`BorrowedMut`) can be created.
    - Multiple immutable references can coexist peacefully. This allows multiple parts of the code to read the data concurrently without interference.

3. **A Mutable Borrow:**
    - Exactly one mutable reference (`BorrowedMut`) to the object exists.
    - While the mutable reference is active:
        - The original owning variable _cannot_ be accessed or mutated directly.
        - Ownership _cannot_ be moved.
        - No other references (neither immutable `Borrowed` nor other mutable `BorrowedMut`) can be created.
    - The object _can_ be mutated through the single active mutable reference. This ensures exclusive write access, preventing data races.

In essence: You can have many readers (`Borrowed`) **or** one writer (`BorrowedMut`), but not both simultaneously. While any borrow is active, the original owner faces restrictions (cannot be moved, cannot be mutated directly if borrowed immutably, cannot be accessed at all if borrowed mutably).

### Sharp Edges

> [!CAUTION]
> Be especially careful with closure functions that capture variables, as
> this is an easy way to silently break the borrowing rules.
> You should always use the `@cc` macro to wrap closures as a form of
> validation:
>
> ```julia
> safe_closure = @cc (x, y) -> x + y
> ```
>
> This will validate that any captured variable is an immutable reference.
> Similarly, you should generally prefer the `BorrowChecker.@spawn` macro instead of
> `Threads.@spawn` to validate captured variables.

## API

### Basics

- `@own [:mut] x [= value]`: Create a new owned value (mutable if `:mut` is specified)
  - These are `Owned{T}` and `OwnedMut{T}` objects, respectively.
  - You can use `@own [:mut] x` as a shorthand for `@own [:mut] x = x` to create owned values at the start of a function.
- `@move [:mut] new = old`: Transfer ownership from one variable to another (mutable destination if `:mut` is specified). _Note that this is simply a more explicit version of `@own` for moving values._
- `@clone [:mut] new = old`: Create a deep copy of a value without moving the source (mutable destination if `:mut` is specified).
- `@take[!] var`: Unwrap an owned value. Using `@take!` will mark the original as moved, while `@take` will perform a copy.
- `getproperty` and `getindex` on owned/borrowed values return a `LazyAccessor` that preserves ownership/lifetime until the raw value is used.
  - For example, for an object `x::Owned{T}`, the accessor `x.a` would return `LazyAccessor{typeof(x.a), T, Val{:a}, Owned{T}}` which has the same reading/writing constraints as the original.


### References and Lifetimes

- `@bc f(args...; kws...)`: This convenience macro automatically creates a lifetime scope for the duration of the function, and sets up borrowing for any owned input arguments.
    - Use `@mut(arg)` to mark an input as mutable.
- `@lifetime lt begin ... end`: Create a scope for references whose lifetimes `lt` are the duration of the block
- `@ref ~lt [:mut] var = value`: Create a reference, for the duration of `lt`, to owned value `value` and assign it to `var` (mutable if `:mut` is specified)
  - These are `Borrowed{T}` and `BorrowedMut{T}` objects, respectively. Use these in the signature of any function you wish to make compatible with references. In the signature you can use `OrBorrowed{T}` and `OrBorrowedMut{T}` to also allow regular `T`.

### Validation

- `@cc closure_expr`: Verifies that closures only capture immutable references.
- `BorrowChecker.@spawn [options...] expr`: A safety wrapper around `Threads.@spawn` that applies `@cc` to the expression (which is internally put inside a closure).

### Loops

- `@own [:mut] for var in iter`: Create a loop over an iterable, assigning ownership of each element to `var`. The original `iter` is marked as moved.
- `@ref ~lt [:mut] for var in iter`: Create a loop over an owned iterable, generating references to each element, for the duration of `lt`.

### Disabling BorrowChecker

You can disable BorrowChecker.jl's functionality by setting `borrow_checker = false` in your LocalPreferences.toml file (using Preferences.jl). When disabled, all macros like `@own`, `@move`, etc., will simply pass through their arguments without any ownership or borrowing checks.

You can also set the _default_ behavior from within a module (make sure to do this at the very top, before any BorrowChecker calls!)

```julia
module MyModule
    using BorrowChecker: disable_by_default!

    disable_by_default!(@__MODULE__)
    #= Other code =#
end
```

This can then be overridden by the LocalPreferences.toml file.

If you wanted to use BorrowChecker in a library, the idea is you could disable it by default with this command, but enable it during testing, to flag any problematic memory patterns.

## Further Examples

### Basic ownership

Let's look at the basic ownership system. When you create an owned value, it's immutable by default:

```julia
@own x = [1, 2, 3]
push!(x, 4)  # ERROR: Cannot write to immutable
```

For mutable values, use the `:mut` flag:

```julia
@own :mut data = [1, 2, 3]
push!(data, 4)  # Works! data is mutable
```

Note that various functions have been overloaded with the write access settings, such as `push!`, `getindex`, etc.

The `@own` macro creates an `Owned{T}` or `OwnedMut{T}` object. Most functions will not be written to accept these, so you can use `@take` (copying) or `@take!` (moving) to extract the owned value:

```julia
# Functions that expect regular Julia types:
push_twice!(x::Vector{Int}) = (push!(x, 4); push!(x, 5); x)

@own x = [1, 2, 3]
@own y = push_twice!(@take!(x))  # Moves ownership of x

push!(x, 4)  # ERROR: Cannot use x: value has been moved
```

However, for recursively immutable types (like tuples of integers), `@take!` is smart enough to know that the original can't change, and thus it won't mark a moved:

```julia
@own point = (1, 2)
sum1 = write_to_file(@take!(point))  # point is still usable
sum2 = write_to_file(@take!(point))  # Works again!
```

This is the same behavior as in Rust (c.f., the `Copy` trait).

There is also the `@take(...)` macro which never marks the original as moved,
and performs a `deepcopy` when needed:

```julia
@own :mut data = [1, 2, 3]
@own total = sum_vector(@take(data))  # Creates a copy
push!(data, 4)  # Original still usable
```

Note also that for improving safety when using BorrowChecker.jl, the macro will actually store the _symbol_ used.
This helps catch mistakes like:

```julia
julia> @own x = [1, 2, 3];

julia> y = x;  # Unsafe! Should use @clone, @move, or @own

julia> @take(y)
ERROR: Variable `y` holds an object that was reassigned from `x`.
```

This won't catch all misuses but it can help prevent some.

### Lifetimes

<details>

References let you temporarily _borrow_ values. This is useful for passing values to functions without moving them. These are created within an explicit `@lifetime` block:

```julia
@own :mut data = [1, 2, 3]

@lifetime lt begin
    @ref ~lt r = data
    @ref ~lt r2 = data  # Can create multiple _immutable_ references!
    @test r == [1, 2, 3]

    # While ref exists, data can't be modified:
    data[1] = 4 # ERROR: Cannot write original while immutably borrowed
end

# After lifetime ends, we can modify again!
data[1] = 4
```

Just like in Rust, while you can create multiple _immutable_ references, you can only have one _mutable_ reference at a time:

```julia
@own :mut data = [1, 2, 3]

@lifetime lt begin
    @ref ~lt :mut r = data
    @ref ~lt :mut r2 = data  # ERROR: Cannot create mutable reference: value is already mutably borrowed
    @ref ~lt r2 = data  # ERROR: Cannot create immutable reference: value is mutably borrowed

    # Can modify via mutable reference:
    r[1] = 4
end
```

When you need to pass immutable references of a value to a function, you would modify the signature to accept a `Borrowed{T}` type. This is similar to the `&T` syntax in Rust. And, similarly, `BorrowedMut{T}` is similar to `&mut T`.

Don't worry about references being used _after_ the lifetime ends, because the `lt` variable will be expired!

```julia
julia> @own x = 1
       @own :mut cheating = []
       @lifetime lt begin
           @ref ~lt r = x
           push!(cheating, r)
       end
       

julia> @show cheating[1]
ERROR: Cannot use r: value's lifetime has expired
```

This makes the use of references inside threads safe, because the threads _must_ finish inside the scope of the lifetime.

Though we can't create multiple mutable references, you _are_ allowed to create multiple mutable references to elements of a collection via the `@ref ~lt for` syntax:

```julia
@own :mut data = [[1], [2], [3]]

@lifetime lt begin
    @ref ~lt :mut for r in data
        push!(r, 4)
    end
end

@show data  # [[1, 4], [2, 4], [3, 4]]
```

</details>

### Mutating owned values

<details>

Note that if you have a mutable owned value,
you can use `setproperty!` and `setindex!` as normal:

```julia
mutable struct A
    x::Int
end

@own :mut a = A(0)
for _ in 1:10
    a.x += 1
end
# Move it to an immutable:
@own a_imm = a
```

And, as expected:

```julia
julia> a_imm.x += 1
ERROR: Cannot write to immutable

julia> a.x += 1
ERROR: Cannot use a: value has been moved
```

**You should never mutate via variable reassignment.**
If needed, you can repeatedly `@own` new objects:

```julia
@own x = 1
for _ in 1:10
    @own x = x + 1
end
```

</details>

### Cloning values

<details>

Sometimes you want to create a completely independent copy of a value.
While you could use `@own new = @take(old)`, the `@clone` macro provides a clearer way to express this intent:

```julia
@own :mut original = [1, 2, 3]
@clone copy = original  # Creates an immutable deep copy
@clone :mut mut_copy = original  # Creates a mutable deep copy

push!(mut_copy, 4)  # Can modify the mutable copy
@test_throws BorrowRuleError push!(copy, 4)  # Can't modify the immutable copy
push!(original, 5)  # Original still usable

@test original == [1, 2, 3, 5]
@test copy == [1, 2, 3]
@test mut_copy == [1, 2, 3, 4]
```

Another macro is `@move`, which is a more explicit version of `@own new = @take!(old)`:

```julia
@own :mut original = [1, 2, 3]
@move new = original  # Creates an immutable deep copy

@test_throws MovedError push!(original, 4)
```

Note that `@own new = old` will also work as a convenience, but `@move` is more explicit and also asserts that the new value is owned.

</details>

### Safe use of closures

<details>

Closures in BorrowChecker.jl must follow strict rules because they capture variables from their enclosing scope:

```julia
let
    @own x = 42
    bad_closure = () -> x + 1  # DANGEROUS: captures owned value
end
```

The `@cc` macro validates that closures follow these rules:

```julia
let
    @own x = 42

    # This fails - owned values can't be captured
    @test_throws ErrorException @cc (a,) -> x + a

    @lifetime lt begin
        @ref ~lt safe_ref = x  # create an immutable reference
        
        # This works - immutable references are safe
        safe_closure = @cc (a,) -> safe_ref + a
    end
    # The reference will expire here, ensuring
    # the closure doesn't break the borrowing rules!
end
```

For threads, you can use the `BorrowChecker.@spawn` macro instead of the standard `Threads.@spawn`.
This ensures safe captures by automatically applying `@cc` to the closure (which is generated internally by `@spawn`):

```julia
@own x = 42
@lifetime lt begin
    @ref ~lt safe_ref = x

    tasks = [
        BorrowChecker.@spawn safe_ref + 1
        for _ in 1:10
    ]
    sum(fetch, tasks)
end
```

</details>

### Automated Borrowing with `@bc`

<details>

The `@bc` macro simplifies calls involving owned variables. Instead of manually creating `@lifetime` blocks and references, you just wrap the function call in `@bc`,
which will create a lifetime scope for the duration of the function call,
and generate references to owned input arguments.
Declare which arguments should be mutable with `@mut(...)`.

```julia
@own config = Dict("enabled" => true)
@own :mut data = [1, 2, 3]

function process(cfg::OrBorrowed{Dict}, arr::OrBorrowedMut{Vector})
    push!(arr, cfg["enabled"] ? 4 : -1)
    return length(arr)
end

@bc process(config, @mut(data))  # => 4
```

Under the hood, `@bc` wraps the function call in a `@lifetime` block, so references end automatically when the call finishes (and thus lose access to the original object).

This approach works with multiple positional and keyword arguments, and is a convenient
way to handle the majority of borrowing patterns. You can freely mix owned, borrowed, and normal Julia values in the same call, and the macro will handle ephemeral references behind the scenes. For cases needing more control or longer lifetimes, manual `@lifetime` usage is a good option.

</details>

### Safe Multi-threading with `Mutex`

<details>

BorrowChecker provides a `Mutex` type analogous to Rust's `Mutex`, for
thread-safe access to shared data, fully integrated with the
ownership and borrowing system.

```julia
julia> m = Mutex([1, 2, 3])
       # ^Regular Julia assignment syntax is fine for Mutexes!
Mutex{Vector{Int64}}([1, 2, 3])

julia> lock(m);

julia> @ref ~m :mut data = m[]
       # ^Mutable reference to the mutex-protected value
BorrowedMut{Vector{Int64},OwnedMut{Vector{Int64}}}([1, 2, 3], :data)

julia> push!(data, 4);

julia> unlock(m);

julia> m
Mutex{Vector{Int64}}([1, 2, 3, 4])
```

The value protected by the mutex is an `OwnedMut` object,
which can therefore be modified.

Because this value is protected by a spinlock, it is safe to pass
around with regular Julia assignment syntax. At any point you wish
to read or write to the value, you can use the `@ref ~m` syntax to
create a reference to the value.

This reference will automatically expire when the lock is released.

```julia
julia> m = Mutex(Dict("count" => 0))
Mutex{Dict{String, Int64}}(Dict("count" => 0))

julia> @sync for i in 1:100
           Threads.@spawn begin
               lock(m) do
                   @ref ~m :mut d = m[]
                   d["count"] += 1
               end
           end
       end

julia> m
Mutex{Dict{String, Int64}}(Dict("count" => 100))

julia> d = lock(m) do
           @ref ~m :mut d = m[]
           d
       end;

julia> d["count"]  # Try to access the value after the lock is released!
ERROR: Cannot use `d`: value's lifetime has expired
```

</details>

### Introducing BorrowChecker.jl to Your Codebase

When introducing BorrowChecker.jl to your codebase, the first thing is to `@own` all variables at the top of a particular function. The simplified version of `@own` is particularly useful in this case:

```julia
function process_data(x, y, z)
    @own x, y
    @own :mut z

    #= body =#
end
```

This pattern is useful for generic functions because if you pass an owned variable as either `x`, `y`, or `z`, the original function will get marked as moved.

The next pattern that is useful is to use `OrBorrowed{T}` (basically equal to `Union{T,Borrowed{<:T}}`) and `OrBorrowedMut{T}` aliases for extending signatures). Let's say you have some function:

```julia
struct Bar{T}
    x::Vector{T}
end

function foo(bar::Bar{T}) where {T}
    sum(bar.x)
end
```

Now, you'd like to modify this so that it can accept _references_ to `Bar` objects from other functions. Since `foo` doesn't need to mutate `bar`, we can modify this as follows:

```julia
function foo(bar::OrBorrowed{Bar{T}}) where {T}
    sum(bar.x)
end
```

Thus, the full `process_data` function might be something like:

```julia
function process_data(x, y, z)
    @own x, y
    @own :mut z

    @lifetime lt begin
        @ref ~lt r = z
        tasks = [
            BorrowChecker.@spawn(foo(r)),
            BorrowChecker.@spawn(foo(r)),
        ]
        sum(fetch, tasks)
    end
end
```

Because we modified `foo` to accept `OrBorrowed{Bar{T}}`, we can safely pass immutable references to `z`, and it will _not_ be marked as moved in the original context! Immutable references are safe to pass in a multi-threaded context, so this doubles as a good way to prevent unintended thread races.
