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
@set
```

## References and Lifetimes

```@docs
@lifetime
@ref
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

## Experimental Features

```@docs
BorrowChecker.Experimental.@managed
``` 
