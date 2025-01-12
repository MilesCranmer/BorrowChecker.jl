module TypesModule

using ..ErrorsModule: MovedError, BorrowRuleError

# Forward declarations
function unsafe_get_value end
function mark_moved! end
function is_moved end
function unsafe_access end
function get_owner end

"""
    abstract type AbstractBound{T} end

Abstract supertype for all bound value types in the BorrowChecker system.
"""
abstract type AbstractBound{T} end

"""
    abstract type AbstractBorrowed{T} end

Abstract supertype for all borrowed reference types in the BorrowChecker system.
"""
abstract type AbstractBorrowed{T} end

"""
    Bound{T}

An immutable bound value. Common operations:
- Create using `@bind x = value`
- Access value using `@take!` (moves) or `@take` (copies)
- Borrow using `@ref`
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Once moved, the value cannot be accessed again.

# Internal fields (not part of public API):

- `value::T`: The contained value
- `moved::Bool`: Whether the value has been moved
- `immutable_borrows::Int`: Count of active immutable borrows
- `symbol::Symbol`: Variable name for error reporting
"""
mutable struct Bound{T} <: AbstractBound{T}
    const value::T
    @atomic moved::Bool
    @atomic immutable_borrows::Int
    const symbol::Symbol

    function Bound{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, symbol)
    end
    function Bound(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return Bound{T}(value, moved, symbol)
    end
end
# TODO: Store a random hash in `get_task_storage` and
#       validate it to ensure we have not moved tasks.

"""
    BoundMut{T}

A mutable bound value. Common operations:
- Create using `@bind :mut x = value`
- Access value using `@take!` (moves) or `@take` (copies)
- Modify using `@set`
- Borrow using `@ref` or `@ref :mut`
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Once moved, the value cannot be accessed again.

# Internal fields (not part of public API):

- `value::T`: The contained value
- `moved::Bool`: Whether the value has been moved
- `immutable_borrows::Int`: Count of active immutable borrows
- `mutable_borrows::Int`: Count of active mutable borrows
- `symbol::Symbol`: Variable name for error reporting
"""
mutable struct BoundMut{T} <: AbstractBound{T}
    @atomic value::T
    @atomic moved::Bool
    @atomic immutable_borrows::Int
    @atomic mutable_borrows::Int
    const symbol::Symbol

    function BoundMut{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, 0, symbol)
    end
    function BoundMut(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return BoundMut{T}(value, moved, symbol)
    end
end

struct Lifetime
    # TODO: Make this atomic
    immutable_refs::Vector{Any}
    mutable_refs::Vector{Any}
    expired::Base.RefValue{Bool}

    Lifetime() = new([], [], Ref(false))
end
# TODO: Need a way to trip the lifetime, so that refs
#       can't be used outside!

# When borrow checker is disabled, in(x, ::NoLifetime) just returns x
struct NoLifetime end

Base.in(x, ::NoLifetime) = x

"""
    Borrowed{T,O<:AbstractBound}

An immutable reference to a bound value. Common operations:
- Create using `@ref lt x = value`
- Access value using `@take` (copies)
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Multiple immutable references can exist simultaneously.
The reference is valid only within its lifetime scope.

# Internal fields (not part of public API):

- `value::T`: The referenced value
- `owner::O`: The original bound value
- `lifetime::Lifetime`: The scope in which this reference is valid
- `symbol::Symbol`: Variable name for error reporting
"""
struct Borrowed{T,O<:AbstractBound} <: AbstractBorrowed{T}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function Borrowed(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:AbstractBound}
        if is_moved(owner)
            throw(MovedError(owner.symbol))
        elseif owner isa BoundMut && owner.mutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create immutable reference: value is mutably borrowed"
                ),
            )
        end

        owner.immutable_borrows += 1
        push!(lifetime.immutable_refs, owner)

        return new{T,O}(value, owner, lifetime, symbol)
    end
    function Borrowed(
        owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {O<:AbstractBound}
        return Borrowed(unsafe_get_value(owner), owner, lifetime, symbol)
    end
end

"""
    BorrowedMut{T,O<:BoundMut}

A mutable reference to a bound value. Common operations:
- Create using `@ref lt :mut x = value`
- Access value using `@take` (copies)
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Only one mutable reference can exist at a time,
and no immutable references can exist simultaneously.

# Internal fields (not part of public API):

- `value::T`: The referenced value
- `owner::O`: The original bound value
- `lifetime::Lifetime`: The scope in which this reference is valid
- `symbol::Symbol`: Variable name for error reporting
"""
struct BorrowedMut{T,O<:BoundMut} <: AbstractBorrowed{T}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function BorrowedMut(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:AbstractBound}
        if !is_mutable(owner)
            throw(BorrowRuleError("Cannot create mutable reference of immutable"))
        elseif is_moved(owner)
            throw(MovedError(owner.symbol))
        elseif owner.immutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is immutably borrowed"
                ),
            )
        elseif owner.mutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is already mutably borrowed"
                ),
            )
        end
        owner.mutable_borrows += 1
        push!(lifetime.mutable_refs, owner)

        return new{T,O}(value, owner, lifetime, symbol)
    end
    function BorrowedMut(
        owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {O<:AbstractBound}
        return BorrowedMut(unsafe_get_value(owner), owner, lifetime, symbol)
    end
    function BorrowedMut(::AbstractBorrowed, ::Lifetime)
        return error("Mutable reference of references not yet implemented.")
    end
end

"""
    LazyAccessor{T,P,S,O<:Union{AbstractBound,AbstractBorrowed}}

A lazy accessor for properties or indices of bound or borrowed values.
Maintains ownership semantics while allowing property/index access without copying or moving.

Created automatically when accessing properties or indices of bound/borrowed values:

```julia
@bind x = (a=1, b=2)
x.a  # Returns a LazyAccessor
```

# Internal fields (not part of public API):

- `parent::P`: The parent value being accessed
- `property::S`: The property/index being accessed
- `property_type::Type{T}`: Type of the accessed property/index
- `target::O`: The original bound/borrowed value
"""
struct LazyAccessor{T,P,S,O<:Union{AbstractBound,AbstractBorrowed}}
    parent::P
    property::S
    property_type::Type{T}
    target::O

    function LazyAccessor(
        x::P, ::Val{property}
    ) where {P<:Union{Bound,BoundMut,Borrowed,BorrowedMut},property}
        parent = unsafe_get_value(x)
        property_type = typeof(getproperty(parent, property))
        return new{property_type,typeof(parent),Val{property},P}(
            parent, Val(property), property_type, x
        )
    end
    function LazyAccessor(x::LazyAccessor, ::Val{subproperty}) where {subproperty}
        target = getfield(x, :target)
        parent = unsafe_access(x)
        property_type = typeof(getproperty(parent, subproperty))
        return new{property_type,typeof(parent),Val{subproperty},typeof(target)}(
            parent, Val(subproperty), property_type, target
        )
    end
    function LazyAccessor(
        x::P, idx::Tuple
    ) where {P<:Union{Bound,BoundMut,Borrowed,BorrowedMut}}
        parent = unsafe_get_value(x)
        property_type = typeof(getindex(parent, idx...))
        return new{property_type,typeof(parent),typeof(idx),P}(
            parent, idx, property_type, x
        )
    end
    function LazyAccessor(x::LazyAccessor, idx::Tuple)
        target = getfield(x, :target)
        parent = unsafe_access(x)
        property_type = typeof(getindex(parent, idx...))
        return new{property_type,typeof(parent),typeof(idx),typeof(target)}(
            parent, idx, property_type, target
        )
    end
end

function BorrowedMut(lazy::LazyAccessor, lt::Lifetime, dest_symbol::Symbol=:anonymous)
    return BorrowedMut(unsafe_access(lazy), get_owner(lazy), lt, dest_symbol)
end
function Borrowed(lazy::LazyAccessor, lt::Lifetime, dest_symbol::Symbol=:anonymous)
    return Borrowed(unsafe_access(lazy), get_owner(lazy), lt, dest_symbol)
end

# Type aliases and traits
const AllBorrowed{T} = AbstractBorrowed{T}
const AllBound{T} = AbstractBound{T}
const AllImmutable{T} = Union{Borrowed{T},Bound{T}}
const AllMutable{T} = Union{BorrowedMut{T},BoundMut{T}}
const AllEager{T} = Union{AllBorrowed{T},AllBound{T}}
const AllWrappers{T} = Union{AllEager{T},LazyAccessor{T}}
const LazyAccessorOf{O} = LazyAccessor{T,P,S,<:O} where {T,P,S}
const OrBorrowed{T} = Union{T,Borrowed{<:T},LazyAccessor{<:T,P,S,<:Borrowed} where {P,S}}
const OrBorrowedMut{T} = Union{
    T,BorrowedMut{<:T},LazyAccessor{<:T,P,S,<:BorrowedMut} where {P,S}
}

# Type-specific utilities
# COV_EXCL_START
is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false
# COV_EXCL_STOP

# Internal getters and setters
unsafe_get_value(r::BoundMut) = getfield(r, :value, :sequentially_consistent)
unsafe_get_value(r::Bound) = getfield(r, :value)
function unsafe_get_value(r::AllBorrowed)
    raw_value = getfield(r, :value)
    if raw_value === get_owner(r)
        return unsafe_get_value(get_owner(r))
    else
        return raw_value
    end
end

@inline function unsafe_access(x::LazyAccessor{T,<:Any,Val{property}}) where {T,property}
    parent = getfield(x, :parent)
    return getproperty(parent, property)::T
end
@inline function unsafe_access(x::LazyAccessor{T,<:Any,<:Tuple}) where {T}
    parent = getfield(x, :parent)
    i = getfield(x, :property)
    return getindex(parent, i...)::T
end

function mark_moved!(r::AllBound)
    return setfield!(r, :moved, true, :sequentially_consistent)
end
function mark_moved!(r::LazyAccessor)
    return mark_moved!(get_owner(r))
end
function is_moved(r::AllBound)
    return getfield(r, :moved, :sequentially_consistent)
end
function is_moved(r::AllBorrowed)
    return is_moved(get_owner(r))
end
function is_expired(r::AllBorrowed)
    return getfield(get_lifetime(r), :expired)[]
end

# Constructor utilities
# COV_EXCL_START
constructorof(::Type{<:Bound}) = Bound
constructorof(::Type{<:BoundMut}) = BoundMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

has_lifetime(::AllBound) = false
has_lifetime(::AllBorrowed) = true
has_lifetime(::LazyAccessor) = false
# COV_EXCL_STOP
# TODO: Should LazyAccessor have its owner be Borrowed?

get_owner(r::AllBound) = r
get_owner(r::AllBorrowed) = getfield(r, :owner)
get_owner(r::LazyAccessor) = get_owner(getfield(r, :target))

get_lifetime(r::AllBorrowed) = getfield(r, :lifetime)
get_lifetime(r::LazyAccessorOf{AllBorrowed}) = get_lifetime(getfield(r, :target))

end
