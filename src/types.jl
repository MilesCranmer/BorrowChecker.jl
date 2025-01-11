module TypesModule

using ..ErrorsModule: MovedError, BorrowRuleError

# Forward declarations
function unsafe_get_value end
function mark_moved! end
function is_moved end
function unsafe_access end
function get_owner end

mutable struct Bound{T}
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

mutable struct BoundMut{T}
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

struct Borrowed{T,O<:Union{Bound,BoundMut}}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function Borrowed(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:Union{Bound,BoundMut}}
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
    ) where {O<:Union{Bound,BoundMut}}
        return Borrowed(unsafe_get_value(owner), owner, lifetime, symbol)
    end
end

struct BorrowedMut{T,O<:BoundMut}
    value::T
    owner::O
    lifetime::Lifetime
    symbol::Symbol

    function BorrowedMut(
        value::T, owner::O, lifetime::Lifetime, symbol::Symbol=:anonymous
    ) where {T,O<:Union{Bound,BoundMut}}
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
    ) where {O<:Union{Bound,BoundMut}}
        return BorrowedMut(unsafe_get_value(owner), owner, lifetime, symbol)
    end
    function BorrowedMut(::Union{Borrowed,BorrowedMut}, ::Lifetime)
        return error("Mutable reference of references not yet implemented.")
    end
end

struct LazyAccessor{T,P,S,O<:Union{Bound,BoundMut,Borrowed,BorrowedMut}}
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
const AllBorrowed{T} = Union{Borrowed{T},BorrowedMut{T}}
const AllBound{T} = Union{Bound{T},BoundMut{T}}
const AllImmutable{T} = Union{Borrowed{T},Bound{T}}
const AllMutable{T} = Union{BorrowedMut{T},BoundMut{T}}
const AllEager{T} = Union{AllBorrowed{T},AllBound{T}}
const AllWrappers{T} = Union{AllEager{T},LazyAccessor{T}}

# Type-specific utilities
is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false

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
    return getfield(r.lifetime, :expired)[]
end

# Constructor utilities
constructorof(::Type{<:Bound}) = Bound
constructorof(::Type{<:BoundMut}) = BoundMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

has_lifetime(::AllBound) = false
has_lifetime(::AllBorrowed) = true
has_lifetime(::LazyAccessor) = false
# TODO: Should LazyAccessor have its owner be Borrowed?

get_owner(r::AllBound) = r
get_owner(r::AllBorrowed) = getfield(r, :owner)
get_owner(r::LazyAccessor) = get_owner(getfield(r, :target))

end
