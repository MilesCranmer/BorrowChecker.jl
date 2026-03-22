# Changelog

## [0.4.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.3...v0.4.4) (2026-01-26)

### Miscellaneous Chores

* fix: issue #49 (#50) (@MilesCranmer)

## [0.4.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.2...v0.4.3) (2026-01-25)

### Miscellaneous Chores

* fix: poorly masked unsafe blocks (#48) (@MilesCranmer)

## [0.4.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.1...v0.4.2) (2026-01-24)

### Miscellaneous Chores

* Create `@unsafe` + rename `@auto` to `@safe` (#46) (@MilesCranmer)
* ci: better treatment of codecov (#47) (@MilesCranmer)

## [0.4.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.4.0...v0.4.1) (2026-01-20)

### Miscellaneous Chores

* Fix variety of edgecases + add debug mode (#43) (@MilesCranmer)
* chore(deps): bump actions/checkout from 4 to 6 (#44) (@dependabot[bot])

## [0.4.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.3.1...v0.4.0) (2026-01-16)

### ⚠ BREAKING CHANGES

* `@auto` switches to compiled check

### Miscellaneous Chores

* chore(deps): bump actions/checkout from 4 to 6 (#33) (@dependabot[bot])
* Recursive borrow checking (#36) (@MilesCranmer)
* Perform borrow checking at compile time (#37) (@MasonProtter)
* feat: handle a subset of foreigncall effects (#38) (@MilesCranmer)

## [0.3.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.3.0...v0.3.1) (2026-01-14)

### Miscellaneous Chores

* Handle `Ptr{T}` better + general cleanup by @MilesCranmer in https://github.com/MilesCranmer/BorrowChecker.jl/pull/35

## [0.3.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.2.1...v0.3.0) (2026-01-14)

### Miscellaneous Chores

* ci: switch to codecov by @MilesCranmer in https://github.com/MilesCranmer/BorrowChecker.jl/pull/31
* Experimental SSA-form IR borrow checker by @MilesCranmer in https://github.com/MilesCranmer/BorrowChecker.jl/pull/34

## [0.2.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.2.0...v0.2.1) (2025-04-27)

### Miscellaneous Chores

* fix LazyAccessor recursive `setproperty!(setindex!(...))` (#30) (@MilesCranmer)

## [0.2.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.5...v0.2.0) (2025-04-27)

### ⚠ BREAKING CHANGES

The `@bc` macro now defaults to creating immutable references, _even if_ you have a mutable reference as an input variable (https://github.com/MilesCranmer/BorrowChecker.jl/pull/29). For example:

```julia
julia> @own :mut x = [1, 2, 3]
OwnedMut{Vector{Int64}}([1, 2, 3], :x)

julia> @lifetime lt begin
           @ref ~lt :mut r = x
           @bc typeof(r)
       end
Borrowed{Vector{Int64}, OwnedMut{Vector{Int64}}}
```

whereas before, this would be a `BorrowedMut`. We can get this behavior again by explicitly marking it as `@mut`.

```julia
julia> @lifetime lt begin
           @ref ~lt :mut r = x
           @bc typeof(@mut(r))
       end
BorrowedMut{Vector{Int64}, OwnedMut{Vector{Int64}}}
```

### Miscellaneous Chores

* feat: allow immutable borrow of mutable borrow (#27) (@MilesCranmer)
* fix: forwarding of `randn` (#28) (@MilesCranmer)
* BREAKING CHANGE: make `@bc` default to immutable (#29) (@MilesCranmer)

## [0.1.5](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.4...v0.1.5) (2025-04-26)

### Miscellaneous Chores

* fix: `@&` when wrapping type parameters (#26) (@MilesCranmer)

## [0.1.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.3...v0.1.4) (2025-04-25)

### Miscellaneous Chores

* refactor: unify abstract types (#19) (@MilesCranmer)
* Create Mutex (#21) (@MilesCranmer)
* feat: add basic broadcasting compatibility (#22) (@MilesCranmer)
* Fix a few type instabilities (#24) (@MilesCranmer)
* feat: create `@&` macro for borrowed types (#25) (@MilesCranmer)

## [0.1.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.2...v0.1.3) (2025-04-13)

### Miscellaneous Chores

* feat: overload `reshape` (#13) (@MilesCranmer)
* Create `@cc`, a closure check macro (#14) (@MilesCranmer)
* Create `@spawn` to validate captures to `Threads.@spawn` (#15) (@MilesCranmer)

## [0.1.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.1...v0.1.2) (2025-04-12)

### Miscellaneous Chores

* feat: overload `adjoint` and `transpose` (#12) (@MilesCranmer)

## [0.1.1](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.1.0...v0.1.1) (2025-04-11)

### Miscellaneous Chores

* More aliasing detection operations (#11) (@MilesCranmer)

## [0.1.0](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.13...v0.1.0) (2025-04-10)

### ⚠ BREAKING CHANGES

None.

### Features

New function overloads for various methods in Base, including `rand`. The RNG object passed must be a mutable.

## [0.0.13](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.12...v0.0.13) (2025-04-09)

### ⚠ BREAKING CHANGES

None

### Features

This version introduces the `@bc` macro to simplify function calls within a BorrowChecker.jl context, by automatically creating temporary borrows.

Consider a function requiring specific borrows:

```julia
function process_items(
    config::OrBorrowed{Dict},
    data::OrBorrowedMut{Vector{Int}},
    threshold::Int
)
    # ... implementation ...
end

@own settings = Dict("enabled" => true)
@own :mut numbers = [1, 5, 2, 8, 3]
```

Previously, passing references to objects required manual lifetime and reference management:

```julia
len = @lifetime lt begin
    @ref ~lt r_settings = settings
    @ref ~lt :mut r_numbers = numbers
    process_items(r_settings, r_numbers, 3)
end
```

With `@bc`, the call becomes much more concise:

```julia
len = @bc process_items(settings, @mut(numbers), 3)
```

`@bc` automatically creates an immutable borrow for `settings` and, guided by `@mut`, performs a mutable borrow for `numbers`. The integer `3` is passed directly. The lifetime of these references is held only for the duration of the `process_items` call, after which, the references are no longer available. In other words, it basically just expands to the `@lifetime` block above!

This significantly reduces boilerplate. Arguments already `Borrowed`/`BorrowedMut` or non-owned types are passed unchanged. Keyword arguments are supported, but splatting (`...`) is not yet implemented. Includes tests too.

### Miscellaneous Chores

* Simplify creation of temporary borrows with `@bc` (#10) (@MilesCranmer)

## [0.0.12](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.11...v0.0.12) (2025-04-08)

### ⚠ BREAKING CHANGES

* Remove `@managed` macro, because Cassette.jl is not well-supported in recent Julia versions.

## [0.0.11](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.10...v0.0.11) (2025-01-20)

### ⚠ BREAKING CHANGES

* Removed `@set` macro as it would change behaviour of disabled code

## [0.0.10](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.9...v0.0.10) (2025-01-20)

### ⚠ BREAKING CHANGES

[none]

## Changes

* Fix cache collision on UUIDs
* Allow `@own` on nested for loops
    ```julia
    @own for i in 1:5, j in 1:5
    end
    ```
* Mark `String` and `Module` as static values to avoid redundant deepcopys

## [0.0.9](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.8...v0.0.9) (2025-01-19)

### ⚠ BREAKING CHANGES

* More overloads for Base

### Features

* Improved errors
* Allowed to use single-arg `@own x` as short-hand for `@own x = x`
* Now allowed to use `@ref` in tuple-unpacking
    ```julia
    @lifetime lt begin
        @ref ~lt (rx, ry) = (x, y)
    end
    ```

## [0.0.8](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.7...v0.0.8) (2025-01-18)

### ⚠ BREAKING CHANGES

* change `disable_borrow_checker!` to `disable_by_default!`

## [0.0.7](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.6...v0.0.7) (2025-01-18)

### ⚠ BREAKING CHANGES

* References now require a `~` in front of the lifetime which helps visually separate it from the variable. So, for example, `@ref lt x = y` is now `@ref ~lt x = y`.
* Allow Julia 1.10
* More `nothing` returns

## [0.0.6](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.5...v0.0.6) (2025-01-16)

### ⚠ BREAKING CHANGES

* Changed `@bind` to `@own`
* Changed `*Bound*` to `*Owned*` for types and type alises

### Miscellaneous Chores

* Renames: `@bind => @own`, `Bound => Owned`, etc. (#3) (@MilesCranmer)

## [0.0.5](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.4...v0.0.5) (2025-01-12)

### ⚠ BREAKING CHANGES

* Avoid deepcopy when `is_static = true` even when borrow checker is turned off, so that we don't perform redundant copies.
* Never validate symbols for borrowed values.

## [0.0.4](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.3...v0.0.4) (2025-01-12)

### ⚠ BREAKING CHANGES

* Expand definition of copyable types to other immutables

## [0.0.3](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.2...v0.0.3) (2025-01-12)

### ⚠ BREAKING CHANGES

* `@take` now creates a `deepcopy` from the extracted value while `@take!` simply extracts (though it marks as moved)

### Miscellaneous Chores

* Added `@managed` block for automatic ownership transfer in function calls using Cassette.jl
* Introduced `LazyAccessor` for safer property access
* Added tuple unpacking support in `@bind`

## [0.0.2](https://github.com/MilesCranmer/BorrowChecker.jl/compare/v0.0.1...v0.0.2) (2025-01-10)

### ⚠ BREAKING CHANGES

0.0.2 has entirely new syntax and many new features.

## [0.0.1](https://github.com/MilesCranmer/BorrowChecker.jl/releases/tag/v0.0.1) (2025-01-10)

Initial release.

