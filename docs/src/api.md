# API Reference

```@meta
CurrentModule = BorrowChecker
```

## Ownership Macros

```@docs
@own
@move
@clone
@take
@take!
```

## References and Lifetimes

```@docs
@lifetime
@ref
Mutex
@ref_into
@bc
@mut
```

## Validation

```@docs
@cc
BorrowChecker.@spawn
```

## Types

```@docs
BorrowChecker.TypesModule.AbstractOwned
BorrowChecker.TypesModule.AbstractBorrowed
Owned
OwnedMut
Borrowed
BorrowedMut
LazyAccessor
OrBorrowed
OrBorrowedMut
```

## Traits

```@docs
is_static
```

## Errors

```@docs
BorrowError
MovedError
BorrowRuleError
SymbolMismatchError
ExpiredError
```

## Internals

Normally, you should rely on `OrBorrowed` and `OrBorrowedMut` to work with borrowed values, or use `@take` and `@take!` to unwrap owned values. However, for convenience, it might be useful to define functions on `Owned` and `OwnedMut` types, if you are confident that your operation will not "move" the input or return a view of it.

Many functions in Base are already overloaded. But if you need to define your own, you can do so by using the `request_value` function and the `AllWrappers` type union.

### Core Types

- `AllWrappers{T}`: A type union that includes all wrapper types (`Owned{T}`, `OwnedMut{T}`, `Borrowed{T}`, `BorrowedMut{T}`, and `LazyAccessor{T}`). This is used to write generic methods that work with any wrapped value.

### Core Functions

- `request_value(x, Val(:read))`: Request read access to a wrapped value
- `request_value(x, Val(:write))`: Request write access to a wrapped value

### Examples

Here's how common operations are overloaded:

1. Binary operations (like `*`) that only need read access:

```julia
function Base.:(*)(l::AllWrappers{<:Number}, r::AllWrappers{<:Number})
    return Base.:(*)(request_value(l, Val(:read)), request_value(r, Val(:read)))
end
```

2. Mutating operations (like `pop!`) that need write access:

```julia
function Base.pop!(r::AllWrappers)
    return Base.pop!(request_value(r, Val(:write)))
end
```

The `request_value` function performs safety checks before allowing access:
- For read access: Verifies the value hasn't been moved
- For write access: Verifies the value is mutable and not borrowed

Note that for operations that need write access, and return a view of the input, it is wise to modify the standard output to return `nothing` instead, which is what we do for `push!`:

```julia
function Base.push!(r::AllWrappers, items...)
    Base.push!(request_value(r, Val(:write)), items...)
    return nothing
end
```

While this violates the expected return type, it is a necessary evil for safety. The `nothing` return will cause loud errors if you have code that relies on this design. This is good! Loud bugs are collaborators; silent bugs are saboteurs.
