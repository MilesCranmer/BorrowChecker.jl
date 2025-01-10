<div align="center">

# BorrowChecker.jl

</div>

> [!WARNING]
> NOTE: This package is under active development and the syntax has not stabilized. Expect it to change significantly between versions.

This package demonstrates Rust-like ownership and borrowing semantics in Julia through a macro-based system that performs runtime checks.

## Usage

In Julia, objects exist independently of the variables that refer to them. When you write `x = [1, 2, 3]` in Julia, the actual _object_ lives in memory completely independently of the symbol, and you can refer to it from as many variables as you want without issue. This does not create a new object, nor does it prevent `x` from being used alongside `y`:

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

@bind x = [1, 2, 3]
@move y = x
println(length(x))
# ERROR: Cannot use x: value has been moved
```

You see, the `@bind` operation has _bound_ the variable `x` with the object `[1, 2, 3]`. The `@move` then moves the object to `y`, and trips a `.moved` flag on `x` so it can't be used by regular operations. 

However, this does not prevent you from cheating the system and using `y = x` (though the code has ways that attempt to flag such mistakes). To use this library, you will need to _buy in_ to the system to get the most out of it. But the good news is that you can introduce it in a library gradually:  add `@bind`, `@move`, etc., inside a single function, and call `@take` when passing objects to external functions. And for convenience, a variety of standard library functions will automatically forward operations on the underlying objects.

First, some important disclaimers:


> [!WARNING]
> BorrowChecker.jl does NOT promise safety in any way. This library implements an _extremely_ simplistic and hacky take on a part of Rust's ownership model. It will not prevent you from misusing it, or using regular Julia features, or doing all sorts of incorrect things. This tool should only be used in development and testing, but should not be relied on in production code to do correct things.


Now, with that out of the way, let's see the reference and then some more detailed examples!

## API

- `@bind [:mut] x = value`: Create a new owned value (mutable if `:mut` is specified)
- `@move [:mut] new = old`: Transfer ownership from one variable to another (mutable destination if `:mut` is specified)
- `@clone [:mut] new = old`: Create a deep copy of a value without moving the source (mutable destination if `:mut` is specified)
- `@take var`: Unwrap an owned value to pass ownership to an external function

### References and Lifetimes

- `@lifetime lt begin ... end`: Create a scope for references whose lifetimes `lt` are the duration of the block
- `@ref lt [:mut] var = value`: Create a reference, for the duration of `lt`, to owned value `value` and assign it to `var` (mutable if `:mut` is specified)

### Assignment

- `@set x = value`: Assign a new value to an existing owned mutable variable

### Property Access

For owned values and references, property access follows these rules:

- `@take x`: Extract the wrapped value of `x`, exiting the BorrowChecker.jl system and allowing direct access to the value. `x` loses ownership and can't be used after this.
- `getproperty`/`setproperty!`: Ownership will be transferred when necessary, and errors will be thrown when determined by ownership rules.

### Loops

- `@bind [:mut] for var in iter`: Create a loop over an iterable, binding each element to `var`. The original `iter` is marked as moved.

### Disabling BorrowChecker

You can disable BorrowChecker.jl's functionality by setting `borrow_checker = false` in your LocalPreferences.toml file (using Preferences.jl). When disabled, all macros like `@bind`, `@move`, etc., will simply pass through their arguments without any ownership or borrowing checks.

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

### Ownership

First, let's look at basic ownership.

```julia
julia> using BorrowChecker

julia> @bind x = [1]
Bound{Vector{Int64}}([1])
```

This is meant to emulate `let x = vec![1]` in Rust.
We can compare it to objects, and the borrow checker will
confirm that we can read it:

```julia
julia> x == [1]
true
```

We could also do this by unpacking the value, which _moves_
ownership:

```julia
julia> (@take x) == [1]
true

julia> x
[moved]

julia> x == [2]
ERROR: Cannot use x: value has been moved
```

Now, let's look at a mutable value:

```julia
julia> @bind :mut y = 1
BoundMut{Int64}(1)
```

We change the contents of this variable using `@set`:

```julia
julia> @set y = 2
BoundMut{Int64}(2)
```

Note that we can't do this with immutable values:

```julia
julia> @bind x = 1;

julia> @set x = 2
ERROR: Cannot assign to immutable
```

This also works with arrays:

```julia
julia> @bind array = [1, 2, 3]
Bound{Vector{Int64}}([1, 2, 3])

julia> push!(array, 4)
ERROR: Cannot write to immutable

julia> @bind :mut array = [1, 2, 3]
BoundMut{Vector{Int64}}([1, 2, 3])

julia> push!(array, 4)
BoundMut{Vector{Int64}}([1, 2, 3, 4])
```

Just like with immutable values, we can move ownership:

```julia
julia> @move array2 = array
Bound{Vector{Int64}}([1, 2, 3, 4])

julia> array
[moved]

julia> array[1] = 5
ERROR: Cannot use array: value has been moved

julia> array2[1] = 5
ERROR: Cannot write to immutable

julia> @move :mut array3 = array2  # Move to mutable
BoundMut{Vector{Int64}}([1, 2, 3, 4])

julia> array3[1] = 5  # Now we can modify it
```

You can also clone values using `@clone`, which calls `deepcopy` under the hood:

```julia
julia> @bind x = [1, 2, 3]
Bound{Vector{Int64}}([1, 2, 3])

julia> @clone :mut y = x  # Create mutable clone
BoundMut{Vector{Int64}}([1, 2, 3])
```

### Borrowing

References must be created within a `@lifetime` block. Let's look at
immutable references first:

```julia
julia> @bind :mut data = [1, 2, 3];

julia> @lifetime a begin
           @ref a ref = data
           ref
       end
Borrowed{Vector{Int64},BoundMut{Vector{Int64}}}([1, 2, 3])
```

Once we have created the reference `ref`, we are no longer allowed to modify
`data` until the lifetime `lt` ends. This helps prevent data races.
After the lifetime ends, we can edit `data` again:

```julia
julia> data[1] = 4; data
BoundMut{Vector{Int64}}([4, 2, 3])
```

Note that we can have multiple _immutable_ references at once:

```julia
julia> @lifetime a begin
           @ref a ref1 = data
           @ref a ref2 = data
           ref1 == ref2
       end
true
```

For mutable references, we can only have one at a time:

```julia
julia> @lifetime a begin
           @ref a :mut mut_ref = data
           @ref a :mut mut_ref2 = data
       end
ERROR: Cannot create mutable reference: value is already mutably borrowed
```

And we can't mix mutable and immutable references:

```julia
julia> @lifetime a begin
           @ref a ref = data
           @ref a :mut mut_ref = data
       end
ERROR: Cannot create mutable reference: value is immutably borrowed
```

We can also use references to temporarily borrow values in functions:

```julia
julia> function borrow_vector(v::Borrowed)  # Signature confirms we only need immutable references
           @assert v == [1, 2, 3]
       end;

julia> @bind vec = [1, 2, 3]
Bound{Vector{Int64}}([1, 2, 3])

julia> @lifetime a begin
           borrow_vector(@ref a d = vec)  # Immutable borrow
       end

julia> vec
Bound{Vector{Int64}}([1, 2, 3])
```

We are also able to clone from reference:

```julia
julia> @bind :mut data = [1, 2, 3]
BoundMut{Vector{Int64}}([1, 2, 3])

julia> @lifetime a begin
           @ref a ref = data
           @clone :mut clone = ref
           clone[2] = 4
           @show clone ref
       end;
clone = BoundMut{Vector{Int64}}([1, 4, 3])
ref = Borrowed{Vector{Int64},BoundMut{Vector{Int64}}}([1, 2, 3])
```

### Loops

Finally, we can use ownership semantics in for loops. By default, loop variables are immutable:

```julia
julia> @bind :mut accumulator = 0
BoundMut{Int64}(0)

julia> @bind :mut for x in 1:3
           @set x = x + 1  # Can modify x since it's mutable
           @set accumulator = accumulator + x
       end

julia> @take accumulator
6
```
