<div align="center">

# BorrowChecker.jl

</div>

> [!CAUTION]
> This is a highly experimental _demonstration_ of Rust-like ownership semantics in Julia. It is not yet intended for active use in libraries.

> [!WARNING]
> NOTE: This package is under active development and the syntax has not stabilized. Expect it to change significantly between versions.

This package demonstrates Rust-like ownership and borrowing semantics in Julia through a macro-based system that performs runtime checks.

## Available Macros

### Ownership

- `@bind [@mut] x = value`: Create a new owned value (mutable if `@mut` is specified)
- `@move [@mut] new = old`: Transfer ownership from one variable to another (mutable destination if `@mut` is specified)
- `@clone [@mut] new = old`: Create a deep copy of a value without moving the source (mutable destination if `@mut` is specified)
- `@take var`: Unwrap an owned value to pass ownership to an external function

### References and Lifetimes

- `@lifetime lt begin ... end`: Create a scope for references whose lifetimes `lt` are the duration of the block
- `@ref [@mut] var = value in lt`: Create a reference to owned value `value` and assign it to `var` within the given lifetime scope `lt` (mutable if `@mut` is specified)

### Assignment

- `@set x = value`: Assign a new value to an existing owned mutable variable

### Property Access

For owned values and references, property access follows these rules:

- Use `@take x` to extract the wrapped value of `x`, exiting the BorrowChecker.jl system and allowing direct access to the value. `x` loses ownership and can't be used after this.
- You can use `getproperty` and `setproperty!` normally on owned values and references. Ownership will be transferred when necessary, and errors will be thrown when determined by ownership rules.

## Examples

### Ownership

First, let's look at basic ownership.

```julia
julia> using BorrowChecker

julia> @bind x = 1
Bound{Int64}(1)
```

This is meant to emulate `let x = 1` in Rust.
We can compare it to objects, and the borrow checker will
confirm that we can read it:

```julia
julia> x == 1
true
```

We could also do this by unpacking the value, which _moves_
ownership:

```julia
julia> (@take x) == 1
true

julia> x
[moved]

julia> x == 2
ERROR: Cannot use x: value has been moved
```

Now, let's look at a mutable value:

```julia
julia> @bind @mut y = 1
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

julia> @bind @mut array = [1, 2, 3]
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

julia> @move @mut array3 = array2  # Move to mutable
BoundMut{Vector{Int64}}([1, 2, 3, 4])

julia> array3[1] = 5  # Now we can modify it
```

You can also clone values using `@clone`, which calls `deepcopy` under the hood:

```julia
julia> @bind x = [1, 2, 3]
Bound{Vector{Int64}}([1, 2, 3])

julia> @clone @mut y = x  # Create mutable clone
BoundMut{Vector{Int64}}([1, 2, 3])
```

### Borrowing

References must be created within a `@lifetime` block. Let's look at
immutable references first:

```julia
julia> @bind @mut data = [1, 2, 3];

julia> @lifetime lt begin
           @ref ref = data in lt
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
julia> @lifetime lt begin
           @ref ref1 = data in lt
           @ref ref2 = data in lt
           ref1 == ref2
       end
true
```

For mutable references, we can only have one at a time:

```julia
julia> @lifetime lt begin
           @ref @mut mut_ref = data in lt
           @ref @mut mut_ref2 = data in lt
       end
ERROR: Cannot create mutable reference: value is already mutably borrowed
```

And we can't mix mutable and immutable references:

```julia
julia> @lifetime lt begin
           @ref ref = data in lt
           @ref @mut mut_ref = data in lt
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

julia> @lifetime lt begin
           borrow_vector(@ref d = vec in lt)  # Immutable borrow
       end

julia> vec
Bound{Vector{Int64}}([1, 2, 3])
```

We are also able to clone from reference:

```julia
julia> @bind @mut data = [1, 2, 3]
BoundMut{Vector{Int64}}([1, 2, 3])

julia> @lifetime lt begin
           @ref ref = data in lt
           @clone @mut clone = ref
           clone[2] = 4
           @show clone ref
       end;
clone = BoundMut{Vector{Int64}}([1, 4, 3])
ref = Borrowed{Vector{Int64},BoundMut{Vector{Int64}}}([1, 2, 3])
```
