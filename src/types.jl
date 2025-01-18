module TypesModule

using ..ErrorsModule: MovedError, BorrowRuleError

# Forward declarations
function unsafe_get_value end
function mark_moved! end
function is_moved end
function unsafe_access end
function get_owner end
function get_lifetime end
function get_symbol end
function get_mutable_borrows end
function get_immutable_borrows end
function increment_mutable_borrows! end
function decrement_mutable_borrows! end
function increment_immutable_borrows! end
function decrement_immutable_borrows! end

"""
    AbstractOwned{T}

Base type for all owned value types in the BorrowChecker system.
"""
abstract type AbstractOwned{T} end

"""
    AbstractBorrowed{T}

Base type for all borrowed reference types in the BorrowChecker system.
"""
abstract type AbstractBorrowed{T} end

"""
    Owned{T}

An immutable owned value. Common operations:
- Create using `@own x = value`
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
mutable struct Owned{T} <: AbstractOwned{T}
    const value::T
    @atomic moved::Bool
    @atomic immutable_borrows::Int
    const symbol::Symbol

    function Owned{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, symbol)
    end
    function Owned(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return Owned{T}(value, moved, symbol)
    end
end
# TODO: Store a random hash in `get_task_storage` and
#       validate it to ensure we have not moved tasks.

"""
    OwnedMut{T}

A mutable owned value. Common operations:
- Create using `@own [:mut] x = value`
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
mutable struct OwnedMut{T} <: AbstractOwned{T}
    @atomic value::T
    @atomic moved::Bool
    @atomic immutable_borrows::Int
    @atomic mutable_borrows::Int
    const symbol::Symbol

    function OwnedMut{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, 0, symbol)
    end
    function OwnedMut(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return OwnedMut{T}(value, moved, symbol)
    end
end

mutable struct Lifetime
    # TODO: Make this atomic
    const immutable_refs::Vector{Any}
    const immutables_lock::Threads.SpinLock
    const mutable_refs::Vector{Any}
    const mutables_lock::Threads.SpinLock
    @atomic expired::Bool

    Lifetime() = new([], Threads.SpinLock(), [], Threads.SpinLock(), false)
end
# TODO: Need a way to trip the lifetime, so that refs
#       can't be used outside!

# When borrow checker is disabled, in(x, ::NoLifetime) just returns x
struct NoLifetime end

Base.in(x, ::NoLifetime) = x

"""
    Borrowed{T,O<:AbstractOwned}

An immutable reference to an owned value. Common operations:
- Create using `@ref lt x = value`
- Access value using `@take` (copies)
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Multiple immutable references can exist simultaneously.
The reference is valid only within its lifetime scope.

# Internal fields (not part of public API):

- `value::T`: The referenced value
- `owner::O`: The original owned value
- `lifetime::Lifetime`: The scope in which this reference is valid
- `symbol::Symbol`: Variable name for error reporting
"""
struct Borrowed{T,O<:AbstractOwned} <: AbstractBorrowed{T}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function Borrowed(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:AbstractOwned}
        if is_moved(owner)
            throw(MovedError(get_symbol(owner)))
        elseif owner isa OwnedMut && get_mutable_borrows(owner) > 0
            throw(
                BorrowRuleError(
                    "Cannot create immutable reference: value is mutably borrowed"
                ),
            )
        end

        increment_immutable_borrows!(owner)
        Base.@lock lifetime.immutables_lock begin
            push!(lifetime.immutable_refs, owner)
        end

        return new{T,O}(value, owner, lifetime, symbol)
    end
    function Borrowed(
        owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {O<:AbstractOwned}
        return Borrowed(unsafe_get_value(owner), owner, lifetime, symbol)
    end
end

"""
    BorrowedMut{T,O<:OwnedMut}

A mutable reference to an owned value. Common operations:
- Create using `@ref lt :mut x = value`
- Access value using `@take` (copies)
- Access fields/indices via `.field` or `[indices...]` (returns LazyAccessor)

Only one mutable reference can exist at a time,
and no immutable references can exist simultaneously.

# Internal fields (not part of public API):

- `value::T`: The referenced value
- `owner::O`: The original owned value
- `lifetime::Lifetime`: The scope in which this reference is valid
- `symbol::Symbol`: Variable name for error reporting
"""
struct BorrowedMut{T,O<:OwnedMut} <: AbstractBorrowed{T}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function BorrowedMut(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:AbstractOwned}
        if !is_mutable(owner)
            throw(BorrowRuleError("Cannot create mutable reference of immutable"))
        elseif is_moved(owner)
            throw(MovedError(get_symbol(owner)))
        elseif get_immutable_borrows(owner) > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is immutably borrowed"
                ),
            )
        elseif get_mutable_borrows(owner) > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is already mutably borrowed"
                ),
            )
        end
        increment_mutable_borrows!(owner)
        Base.@lock lifetime.mutables_lock begin
            push!(lifetime.mutable_refs, owner)
        end

        return new{T,O}(value, owner, lifetime, symbol)
    end
    function BorrowedMut(
        owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {O<:AbstractOwned}
        return BorrowedMut(unsafe_get_value(owner), owner, lifetime, symbol)
    end
    function BorrowedMut(::AbstractBorrowed, ::Lifetime)
        return error("Mutable reference of references not yet implemented.")
    end
end

"""
    LazyAccessor{T,P,S,O<:Union{AbstractOwned,AbstractBorrowed}}

A lazy accessor for properties or indices of owned or borrowed values.
Maintains ownership semantics while allowing property/index access without copying or moving.

Created automatically when accessing properties or indices of owned/borrowed values:

```julia
@own x = (a=1, b=2)
x.a  # Returns a LazyAccessor
```

# Internal fields (not part of public API):

- `parent::P`: The parent value being accessed
- `property::S`: The property/index being accessed
- `property_type::Type{T}`: Type of the accessed property/index
- `target::O`: The original owned/borrowed value
"""
struct LazyAccessor{T,P,S,O<:Union{AbstractOwned,AbstractBorrowed}}
    parent::P
    property::S
    property_type::Type{T}
    target::O

    function LazyAccessor(
        x::P, ::Val{property}
    ) where {P<:Union{Owned,OwnedMut,Borrowed,BorrowedMut},property}
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
    ) where {P<:Union{Owned,OwnedMut,Borrowed,BorrowedMut}}
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
const AllOwned{T} = AbstractOwned{T}
const AllImmutable{T} = Union{Borrowed{T},Owned{T}}
const AllMutable{T} = Union{BorrowedMut{T},OwnedMut{T}}
const AllEager{T} = Union{AllBorrowed{T},AllOwned{T}}
const AllWrappers{T} = Union{AllEager{T},LazyAccessor{T}}
const LazyAccessorOf{O} = LazyAccessor{T,P,S,<:O} where {T,P,S}

"""
    OrBorrowed{T}

Type alias for accepting either a value of type `T` or a borrowed reference to it.
"""
const OrBorrowed{T} = Union{T,Borrowed{<:T},LazyAccessor{<:T,P,S,<:Borrowed} where {P,S}}

"""
    OrBorrowedMut{T}

Type alias for accepting either a value of type `T` or a mutable borrowed reference to it.
"""
const OrBorrowedMut{T} = Union{
    T,BorrowedMut{<:T},LazyAccessor{<:T,P,S,<:BorrowedMut} where {P,S}
}

# Type-specific utilities
# COV_EXCL_START
is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false
# COV_EXCL_STOP

# Internal getters and setters
unsafe_get_value(r::OwnedMut) = getfield(r, :value, :sequentially_consistent)
unsafe_get_value(r::Owned) = getfield(r, :value)
unsafe_get_value(r::AllBorrowed) = getfield(r, :value)
function unsafe_set_value!(r::OwnedMut, value)
    return setfield!(r, :value, value, :sequentially_consistent)
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

function mark_moved!(r::AllOwned)
    return setfield!(r, :moved, true, :sequentially_consistent)
end
function mark_moved!(r::LazyAccessor)
    return mark_moved!(get_owner(r))
end

function is_moved(r::AllOwned)
    return getfield(r, :moved, :sequentially_consistent)
end
function is_moved(r::AllBorrowed)
    return is_moved(get_owner(r))
end
function is_moved(r::LazyAccessor)
    return is_moved(get_owner(r))
end

function mark_expired!(lt::Lifetime)
    return setfield!(lt, :expired, true, :sequentially_consistent)
end
function is_expired(lt::Lifetime)
    return getfield(lt, :expired, :sequentially_consistent)
end
function is_expired(r::AllBorrowed)
    return is_expired(get_lifetime(r))
end

# Constructor utilities
# COV_EXCL_START
constructorof(::Type{<:Owned}) = Owned
constructorof(::Type{<:OwnedMut}) = OwnedMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

has_lifetime(::AllOwned) = false
has_lifetime(::AllBorrowed) = true
has_lifetime(::LazyAccessor) = false
# COV_EXCL_STOP
# TODO: Should LazyAccessor have its owner be Borrowed?

get_owner(r::AllOwned) = r
get_owner(r::AllBorrowed) = getfield(r, :owner)
get_owner(r::LazyAccessor) = get_owner(getfield(r, :target))

get_lifetime(r::AllBorrowed) = getfield(r, :lifetime)
get_lifetime(r::LazyAccessorOf{AllBorrowed}) = get_lifetime(getfield(r, :target))

get_symbol(r::AllEager) = getfield(r, :symbol)

function get_immutable_borrows(r::AllOwned)
    return getfield(r, :immutable_borrows, :sequentially_consistent)
end

get_mutable_borrows(r::OwnedMut) = getfield(r, :mutable_borrows, :sequentially_consistent)

@inline function _change_immutable_borrows!(r::AllOwned, change::Int)
    borrows = get_immutable_borrows(r)
    return setfield!(r, :immutable_borrows, borrows + change, :sequentially_consistent)
end
@inline increment_immutable_borrows!(r::AllOwned) = _change_immutable_borrows!(r, 1)
@inline decrement_immutable_borrows!(r::AllOwned) = _change_immutable_borrows!(r, -1)

@inline function _change_mutable_borrows!(r::OwnedMut, change::Int)
    borrows = get_mutable_borrows(r)
    return setfield!(r, :mutable_borrows, borrows + change, :sequentially_consistent)
end
@inline increment_mutable_borrows!(r::OwnedMut) = _change_mutable_borrows!(r, 1)
@inline decrement_mutable_borrows!(r::OwnedMut) = _change_mutable_borrows!(r, -1)

end
