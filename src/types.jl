module TypesModule

using ..ErrorsModule: MovedError, BorrowRuleError
using ..UtilsModule: recursive_ismutable

# Forward declarations
function unsafe_get_value end
function mark_moved! end
function is_moved end

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
    immutable_refs::Vector{Any}
    mutable_refs::Vector{Any}

    Lifetime() = new([], [])
end

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

# Type aliases and traits
const AllBorrowed{T} = Union{Borrowed{T},BorrowedMut{T}}
const AllBound{T} = Union{Bound{T},BoundMut{T}}
const AllImmutable{T} = Union{Borrowed{T},Bound{T}}
const AllMutable{T} = Union{BorrowedMut{T},BoundMut{T}}
const AllWrappers{T} = Union{AllBorrowed{T},AllBound{T}}

# Type-specific utilities
is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false

# Internal getters and setters
unsafe_get_value(r::BoundMut) = getfield(r, :value, :sequentially_consistent)
unsafe_get_value(r::Bound) = getfield(r, :value)
function unsafe_get_value(r::AllBorrowed)
    raw_value = getfield(r, :value)
    if raw_value === r.owner
        return unsafe_get_value(r.owner)
    else
        return raw_value
    end
end

function mark_moved!(r::AllBound)
    return setfield!(r, :moved, true, :sequentially_consistent)
end
function is_moved(r::AllBound)
    return getfield(r, :moved, :sequentially_consistent)
end
function is_moved(r::AllBorrowed)
    return is_moved(r.owner)
end

# Constructor utilities
constructorof(::Type{<:Bound}) = Bound
constructorof(::Type{<:BoundMut}) = BoundMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

end
