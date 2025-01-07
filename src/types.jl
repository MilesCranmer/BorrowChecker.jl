mutable struct Owned{T}
    const value::T
    moved::Bool
    immutable_borrows::Int
    symbol::Symbol

    function Owned{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, symbol)
    end
    function Owned(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return Owned{T}(value, moved, symbol)
    end
end

mutable struct OwnedMut{T}
    value::T
    moved::Bool
    immutable_borrows::Int
    mutable_borrows::Int
    symbol::Symbol

    function OwnedMut{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, 0, symbol)
    end
    function OwnedMut(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return OwnedMut{T}(value, moved, symbol)
    end
end

struct Lifetime
    immutable_refs::Vector{Any}
    mutable_refs::Vector{Any}

    Lifetime() = new([], [])
end

struct Borrowed{T,O<:Union{Owned,OwnedMut}}
    value::T
    owner::O
    lifetime::Lifetime

    function Borrowed(
        value::T, owner::O, lifetime::Lifetime
    ) where {T,O<:Union{Owned,OwnedMut}}
        if owner.moved
            throw(MovedError(owner.symbol))
        elseif owner isa OwnedMut && owner.mutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create immutable reference: value is mutably borrowed"
                ),
            )
        end

        owner.immutable_borrows += 1
        push!(lifetime.immutable_refs, owner)

        return new{T,O}(value, owner, lifetime)
    end
    function Borrowed(owner::O, lifetime::Lifetime) where {O<:Union{Owned,OwnedMut}}
        return Borrowed(unsafe_get_value(owner), owner, lifetime)
    end
end

struct BorrowedMut{T,O<:OwnedMut}
    value::T
    owner::O
    lifetime::Lifetime

    function BorrowedMut(
        value::T, owner::O, lifetime::Lifetime
    ) where {T,O<:Union{Owned,OwnedMut}}
        if !is_mutable(owner)
            throw(BorrowRuleError("Cannot create mutable reference of immutable"))
        elseif owner.moved
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

        return new{T,O}(value, owner, lifetime)
    end
    function BorrowedMut(owner::O, lifetime::Lifetime) where {O<:Union{Owned,OwnedMut}}
        return BorrowedMut(unsafe_get_value(owner), owner, lifetime)
    end
    function BorrowedMut(::Union{Borrowed,BorrowedMut}, ::Lifetime)
        return error("Mutable reference of references not yet implemented.")
    end
end

# Type aliases and traits
const AllBorrowed{T} = Union{Borrowed{T},BorrowedMut{T}}
const AllOwned{T} = Union{Owned{T},OwnedMut{T}}
const AllImmutable{T} = Union{Borrowed{T},Owned{T}}
const AllMutable{T} = Union{BorrowedMut{T},OwnedMut{T}}
const AllWrappers{T} = Union{AllBorrowed{T},AllOwned{T}}
