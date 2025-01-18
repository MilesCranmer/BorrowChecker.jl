<div align="center">

# BorrowChecker.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://astroautomata.com/BorrowChecker.jl/dev)
[![Build Status](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/MilesCranmer/BorrowChecker.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://coveralls.io/repos/github/MilesCranmer/BorrowChecker.jl/badge.svg?branch=main)](https://coveralls.io/github/MilesCranmer/BorrowChecker.jl?branch=main)

</div>

This package demonstrates Rust-like ownership and borrowing semantics in Julia through a macro-based system that performs runtime checks. This tool is mainly to be used in development and testing to flag memory safety issues, and help you design safer code.

> [!WARNING]
> BorrowChecker.jl does not promise memory safety. This library simulates aspects of Rust's ownership model, but it does not do this at a compiler level, and does not do this with any of the same guarantees. Furthermore, BorrowChecker.jl heavily relies on the user's cooperation, and will not prevent you from misusing it, or from mixing it with regular Julia code.

## Usage

In Julia, objects exist independently of the variables that refer to them. When you write `x = [1, 2, 3]` in Julia, the actual _object_ lives in memory completely independently of the symbol, and you can refer to it from as many variables as you want without issue:

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

The purpose of this "ownership" paradigm is to improve safety of code. Especially in complex, multithreaded codebases, it is really easy to shoot yourself in the foot and modify objects which are "owned" (editable) by something else. Rust's ownership and lifetime model makes it so that you can _prove_ memory safety of code! Standard thread races are literally impossible. (Assuming you are not using `unsafe { ... }` to disable safety features, or rust itself has a bug, or a cosmic ray hits your PC!)

In BorrowChecker.jl, we demonstrate a very simple implementation of some of these core ideas. The aim is to build a development layer that, eventually, can help prevent a few classes of memory safety issues, without affecting runtime behavior of code. The above example, with BorrowChecker.jl, would look like this:

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
    @ref a y = x
    #= operations on reference =#
end
```

Note that BorrowChecker.jl does not prevent you from cheating the system and using `y = x`[^1]. To use this library, you will need to _buy in_ to the system to get the most out of it. But the good news is that you can introduce it in a library gradually:  add `@own`, `@move`, etc., inside a single function, and call `@take!` when passing objects to external functions. And for convenience, a variety of standard library functions will automatically forward operations on the underlying objects.

[^1]: Luckily, the library has a way to try flag such mistakes by recording symbols used in the macro.

## API

> [!CAUTION]
> The API is under active development and may change in future versions.

### Basics

- `@own [:mut] x = value`: Create a new owned value (mutable if `:mut` is specified)
    - These are `Owned{T}` and `OwnedMut{T}` objects, respectively.
- `@move [:mut] new = old`: Transfer ownership from one variable to another (mutable destination if `:mut` is specified). _Note that this is simply a more explicit version of `@own` for moving values._
- `@clone [:mut] new = old`: Create a deep copy of a value without moving the source (mutable destination if `:mut` is specified).
- `@take[!] var`: Unwrap an owned value. Using `@take!` will mark the original as moved, while `@take`will perform a copy.

### References and Lifetimes

- `@lifetime lt begin ... end`: Create a scope for references whose lifetimes `lt` are the duration of the block
- `@ref lt [:mut] var = value`: Create a reference, for the duration of `lt`, to owned value `value` and assign it to `var` (mutable if `:mut` is specified)
    - These are `Borrowed{T}` and `BorrowedMut{T}` objects, respectively. Use these in the signature of any function you wish to make compatible with references. In the signature you can use `OrBorrowed{T}` and `OrBorrowedMut{T}` to also allow regular `T`.

### Automatic Ownership Transfer

- `BorrowChecker.Experimental.@managed begin ... end`: create a scope where contextual dispatch is performed using [Cassette.jl](https://github.com/JuliaLabs/Cassette.jl): recursively, all functions (_**in all dependencies**_) are automatically modified to apply `@take!` to any `Owned{T}` or `OwnedMut{T}` input arguments.
    - Note: this is an experimental feature that may change or be removed in future versions. It relies on compiler internals and seems to break on certain functions (like SIMD operations).

### Assignment

- `@set x = value`: Assign a new value to an existing owned mutable variable

### Loops

- `@own [:mut] for var in iter`: Create a loop over an iterable, assigning ownership of each element to `var`. The original `iter` is marked as moved.
- `@ref lt [:mut] for var in iter`: Create a loop over an owned iterable, generating references to each element, for the duration of `lt`.

### Disabling BorrowChecker

You can disable BorrowChecker.jl's functionality by setting `borrow_checker = false` in your LocalPreferences.toml file (using Preferences.jl). When disabled, all macros like `@own`, `@move`, etc., will simply pass through their arguments without any ownership or borrowing checks.

You can also set the _default_ behavior from within a module:

```julia
module MyModule
    using BorrowChecker: disable_borrow_checker!

    disable_borrow_checker!(@__MODULE__)
    #= Other code =#
end
```

This can then be overridden by the LocalPreferences.toml file.

## Further Examples

### Basic Ownership

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

### References and Lifetimes

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

There are the `OrBorrowed{T}` (basically `==Union{T,Borrowed{<:T}}`) and `OrBorrowedMut{T}` aliases for easily extending a signature. Let's say you have some function:

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

Now, we can modify our calling code (which might be multithreaded) to be something like:

```julia
@own :mut bar = Bar([1, 2, 3])

@lifetime lt begin
    @ref ~lt r1 = bar
    @ref ~lt r2 = bar
    
    @own tasks = [
        Threads.@spawn(foo(r1))
        Threads.@spawn(foo(r2))
    ]
    @show map(fetch, @take!(tasks))
end

# After lifetime ends, we can modify `bar` again
```
Immutable references are safe to pass in a multi-threaded context, so this is a good way to prevent thread races.
Using immutable references enforces that (a) the original object cannot be modified, and (b) there are no mutable references active.

Another trick: don't worry about references being used _after_ the lifetime ends, because the `lt` variable will be expired!

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

Though we can't create multiple mutable references, you _are_ allowed to create multiple mutable references to elements of a collection via the `@ref for` syntax:

```julia
@own :mut data = [[1], [2], [3]]

@lifetime lt begin
    @ref ~lt :mut for r in data
        push!(r, 4)
    end
end

@show data  # [[1, 4], [2, 4], [3, 4]]
```

### Automatic Ownership

The (experimental) `@managed` block can be used to perform borrow checking automatically. It basically transforms all functions, everywhere, to perform `@take!` on function calls that take `Owned{T}` or `OwnedMut{T}` arguments:

```julia
struct Particle
    position::Vector{Float64}
    velocity::Vector{Float64}
end

function update!(p::Particle)
    p.position .+= p.velocity
    return p
end
```

With `@managed`, you don't need to manually move ownership:

```julia
julia> using BorrowChecker.Experimental: @managed

julia> @own :mut p = Particle([0.0, 0.0], [1.0, 1.0])
       @managed begin
           update!(p)
       end;

julia> p
[moved]
```

This works via [Cassette.jl](https://github.com/JuliaLabs/Cassette.jl) overdubbing, which recursively modifies all function calls in the entire call stack - not just the top-level function, but also any functions it calls, and any functions those functions call, and so on. But do note that this is very experimental as it modifies the compilation itself. For more robust usage, just use `@take!` manually.

This also works with nested field access, just like in Rust:

```julia
struct Container
    x::Vector{Int}
end

f!(x::Vector{Int}) = push!(x, 3)

@own a = Container([2])
@managed begin
    f!(a.x)  # Container ownership handled automatically
end

@take!(a)  # ERROR: Cannot use a: value has been moved
```

### Mutating Owned Values

For mutating an owned value directly, you should use the `@set` macro,
which prevents the creation of a new owned value.

```julia
@own :mut local_counter = 0
for _ in 1:10
    @set local_counter = local_counter + 1
end
@take! local_counter
```

But note that if you have a mutable struct, you can just use `setproperty!` as normal:

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

### Cloning Values

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
