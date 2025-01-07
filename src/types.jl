module TypesModule

using ..ErrorsModule: MovedError, BorrowRuleError
using ..UtilsModule: recursive_ismutable

# Forward declarations
function unsafe_get_value end
function mark_moved! end
function is_moved end

mutable struct Owned{T}
    const value::T
    moved::Bool
    immutable_borrows::Int
    const symbol::Symbol
    const threadid::Int

    function Owned{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, symbol, Threads.threadid())
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
    const symbol::Symbol
    const threadid::Int

    function OwnedMut{T}(value::T, moved::Bool=false, symbol::Symbol=:anonymous) where {T}
        return new{T}(value, moved, 0, 0, symbol, Threads.threadid())
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
        if is_moved(owner)
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

# Type-specific utilities
is_same_thread(r::AllOwned) = Threads.threadid() == getfield(r, :threadid)
is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false

# Internal getters and setters
function unsafe_get_value(r::AllOwned)
    return getfield(r, :value)
end
function unsafe_get_value(r::AllBorrowed)
    raw_value = getfield(r, :value)
    if raw_value === r.owner
        return unsafe_get_value(r.owner)
    else
        return raw_value
    end
end

function mark_moved!(r::AllOwned)
    return setfield!(r, :moved, true)
end
function is_moved(r::AllOwned)
    return getfield(r, :moved)
end
function is_moved(r::AllBorrowed)
    return is_moved(r.owner)
end

# Constructor utilities
constructorof(::Type{<:Owned}) = Owned
constructorof(::Type{<:OwnedMut}) = OwnedMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

end
