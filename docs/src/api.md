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
Owned
OwnedMut
Borrowed
BorrowedMut
LazyAccessor
OrBorrowed
OrBorrowedMut
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
