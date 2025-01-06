module BorrowChecker

using MacroTools
using MacroTools: rmlines

export @own, @own_mut, @move, @ref, @ref_mut, @take, @set, @lifetime
export Owned, OwnedMut, Borrowed, BorrowedMut
export MovedError, BorrowError, BorrowRuleError

# --- ERROR TYPES ---
abstract type BorrowError <: Exception end

struct MovedError <: BorrowError
    var::Symbol
end

struct BorrowRuleError <: BorrowError
    msg::String
end

Base.showerror(io::IO, e::MovedError) =
    print(io, "Cannot use $(e.var): value has been moved")
Base.showerror(io::IO, e::BorrowRuleError) = print(io, e.msg)
# --- END ERROR TYPES ---

# --- CORE TYPES ---
mutable struct Owned{T}
    const value::T
    moved::Bool
    immutable_borrows::Int

    Owned{T}(value::T, moved::Bool = false) where {T} = new{T}(value, moved, 0)
    Owned(value::T, moved::Bool = false) where {T} = Owned{T}(value, moved)
end

mutable struct OwnedMut{T}
    value::T
    moved::Bool
    immutable_borrows::Int
    mutable_borrows::Int

    OwnedMut{T}(value::T, moved::Bool = false) where {T} = new{T}(value, moved, 0, 0)
    OwnedMut(value::T, moved::Bool = false) where {T} = OwnedMut{T}(value, moved)
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

    function Borrowed(value::T, owner::O, lifetime::Lifetime) where {T,O<:Union{Owned,OwnedMut}}
        if owner.moved
            throw(MovedError(:owner))
        elseif owner isa OwnedMut && owner.mutable_borrows > 0
            throw(BorrowRuleError("Cannot create immutable reference: value is mutably borrowed"))
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

    function BorrowedMut(value::T, owner::O, lifetime::Lifetime) where {T,O<:Union{Owned,OwnedMut}}
        if !is_mutable(owner)
            throw(BorrowRuleError("Cannot create mutable reference of immutable"))
        elseif owner.moved
            throw(MovedError(:owner))
        elseif owner.immutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is immutably borrowed",
                ),
            )
        elseif owner.mutable_borrows > 0
            throw(
                BorrowRuleError(
                    "Cannot create mutable reference: value is already mutably borrowed",
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
        error("Mutable reference of references not yet implemented.")
    end
end
# --- END CORE TYPES ---

# --- UTILITY TYPES AND TRAITS ---
const AllBorrowed{T} = Union{Borrowed{T},BorrowedMut{T}}
const AllOwned{T} = Union{Owned{T},OwnedMut{T}}
const AllImmutable{T} = Union{Borrowed{T},Owned{T}}
const AllMutable{T} = Union{BorrowedMut{T},OwnedMut{T}}
const AllWrappers{T} = Union{AllBorrowed{T},AllOwned{T}}

constructorof(::Type{<:Owned}) = Owned
constructorof(::Type{<:OwnedMut}) = OwnedMut
constructorof(::Type{<:Borrowed}) = Borrowed
constructorof(::Type{<:BorrowedMut}) = BorrowedMut

is_mutable(r::AllMutable) = true
is_mutable(r::AllImmutable) = false
# --- END UTILITY TYPES AND TRAITS ---

# --- INTERNAL GETTERS AND SETTERS ---

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

function request_value(r::AllOwned, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    if r.moved
        throw(MovedError(:value))
    elseif is_mutable(r) && r.mutable_borrows > 0
        throw(BorrowRuleError("Cannot access original while mutably borrowed"))
    elseif mode == :write
        if !is_mutable(r)
            throw(BorrowRuleError("Cannot write to immutable"))
        elseif r.immutable_borrows > 0
            throw(BorrowRuleError("Cannot write to original while immutably borrowed"))
        end
    end
    return unsafe_get_value(r)
end
function request_value(r::AllBorrowed, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    owner = r.owner
    if owner.moved
        throw(MovedError(:owner))
    elseif mode == :write && !is_mutable(r)
        throw(BorrowRuleError("Cannot write to immutable reference"))
    end
    return unsafe_get_value(r)
end

function unsafe_set_value!(r::OwnedMut, value)
    return setfield!(r, :value, value)
end
function set_value!(r::AllOwned, value)
    if !is_mutable(r)
        throw(BorrowRuleError("Cannot assign to immutable"))
    elseif r.moved
        throw(MovedError(:value))
    elseif r.mutable_borrows > 0 || r.immutable_borrows > 0
        throw(BorrowRuleError("Cannot assign to value while borrowed"))
    end
    return unsafe_set_value!(r, value)
end
function set_value!(::AllBorrowed, value)
    throw(BorrowRuleError("Cannot assign to borrowed"))
end
# --- END INTERNAL GETTERS AND SETTERS ---

# --- PUBLIC GETTERS AND SETTERS ---
function Base.getproperty(o::AllOwned, name::Symbol)
    if name == :value
        error("Use `@take` to directly access the value of an owned variable")
    end
    if name in (:moved, :immutable_borrows, :mutable_borrows)
        return getfield(o, name)
    else
        value = request_value(o, Val(:read))
        if recursive_ismutable(value)
            # TODO: This is kind of where rust would check
            #       the Copy trait. What should we do?
            mark_moved!(o)
            return constructorof(typeof(o))(getproperty(value, name))
        else
            return constructorof(typeof(o))(getproperty(value, name))
        end
    end
end
function Base.setproperty!(o::AllOwned, name::Symbol, v)
    if name in (:moved, :immutable_borrows, :mutable_borrows)
        setfield!(o, name, v)
    else
        value = request_value(o, Val(:write))
        setproperty!(value, name, v)
    end
    return o
end
function Base.getproperty(r::AllBorrowed, name::Symbol)
    if name == :owner
        return getfield(r, :owner)
    elseif name == :lifetime
        return getfield(r, :lifetime)
    end
    value = getproperty(request_value(r, Val(:read)), name)
    return constructorof(typeof(r))(value, r.owner, r.lifetime)
end
function Base.setproperty!(r::AllBorrowed, name::Symbol, value)
    name == :owner && error("Cannot modify reference ownership")
    result = setproperty!(request_value(r, Val(:write)), name, value)
    return constructorof(typeof(r))(result, r.owner, r.lifetime)
end
# --- END PUBLIC GETTERS AND SETTERS ---

# --- CONVENIENCE FUNCTIONS ---
function Base.propertynames(o::AllWrappers)
    return propertynames(unsafe_get_value(o))
end
function Base.show(io::IO, o::AllOwned)
    if o.moved
        print(io, "[moved]")
    else
        constructor = constructorof(typeof(o))
        value = request_value(o, Val(:read))
        print(io, "$(constructor){$(typeof(value))}($(value))")
    end
end
function Base.show(io::IO, r::AllBorrowed)
    if r.owner.moved
        print(io, "[reference to moved value]")
    else
        constructor = constructorof(typeof(r))
        value = request_value(r, Val(:read))
        owner = r.owner
        print(io, "$(constructor){$(typeof(value)),$(typeof(owner))}($(value))")
    end
end
# --- END CONVENIENCE FUNCTIONS ---

# --- CONTAINER OPERATIONS ---
function Base.setindex!(r::AllWrappers, value, i...)
    setindex!(request_value(r, Val(:write)), value, i...)
    # TODO: This is not good Julia style, but otherwise we would
    #       need to return a new owned object. We have to break
    #       a lot of conventions here for safety.
    return nothing
end
function Base.getindex(o::AllOwned{<:AbstractArray{T}}, i...) where {T}
    # We mark_moved! if the elements of this array are mutable,
    # because we can't be sure whether the elements will get mutated
    # or not.
    if recursive_ismutable(T)
        mark_moved!(o)
    end
    # Create a new owned object holding the indexed version:
    return constructorof(typeof(o))(getindex(request_value(o, Val(:read)), i...))
end

Base.length(r::AllWrappers) = length(request_value(r, Val(:read)))
Base.size(r::AllWrappers) = size(request_value(r, Val(:read)))
Base.axes(r::AllWrappers) = axes(request_value(r, Val(:read)))
Base.firstindex(r::AllWrappers) = firstindex(request_value(r, Val(:read)))
Base.lastindex(r::AllWrappers) = lastindex(request_value(r, Val(:read)))

# Forward comparison to the underlying value
Base.:(==)(r::AllWrappers, other) = request_value(r, Val(:read)) == other
Base.:(==)(other, r::AllWrappers) = other == request_value(r, Val(:read))
Base.:(==)(r::AllWrappers, other::AllWrappers) = request_value(r, Val(:read)) == request_value(other, Val(:read))

# Forward array operations for mutable wrappers
Base.push!(r::AllWrappers, items...) = (push!(request_value(r, Val(:write)), items...); r)
Base.append!(r::AllWrappers, items) = (append!(request_value(r, Val(:write)), items); r)
Base.pop!(r::AllWrappers) = (pop!(request_value(r, Val(:write))); r)
Base.popfirst!(r::AllWrappers) = (popfirst!(request_value(r, Val(:write))); r)
Base.empty!(r::AllWrappers) = (empty!(request_value(r, Val(:write))); r)
Base.resize!(r::AllWrappers, n) = (resize!(request_value(r, Val(:write)), n); r)
# --- END CONTAINER OPERATIONS ---

# TODO: Add other interfaces


# --- MACROS ---
"""
    @own x = value

Create a new owned immutable value.
"""
macro own(expr)
    if !Meta.isexpr(expr, :(=))
        error("@own requires an assignment expression")
    end
    name = expr.args[1]
    value = expr.args[2]
    return esc(:($(name) = Owned($(value))))
end

"""
    @own_mut x = value

Create a new owned mutable value.
"""
macro own_mut(expr)
    if !Meta.isexpr(expr, :(=))
        error("@own_mut requires an assignment expression")
    end
    name = expr.args[1]
    value = expr.args[2]
    return esc(:($(name) = OwnedMut($(value))))
end

"""
    @move new = old

Transfer ownership from one variable to another, invalidating the old variable.
"""
macro move(expr)
    if !Meta.isexpr(expr, :(=))
        error("@move requires an assignment expression (e.g., @move y = x)")
    end

    # Handle assignment case (e.g., @move y = x)
    dest = expr.args[1]
    src = expr.args[2]
    value = gensym(:value)

    return esc(quote
        $value = $(request_value)($src, Val(:read))
        # Create same type as source
        $dest = $(constructorof)(typeof($src))($value)
        $(mark_moved!)($src)
        $dest
    end)
end

"""
    @take var

Take ownership of a value, typically used in function arguments.
Returns the inner value and marks the original as moved.
"""
macro take(var)
    value = gensym(:value)
    return esc(quote
        $value = $(request_value)($var, $(Val(:read)))
        $(mark_moved!)($var)
        $value
    end)
end

"""
    @set x = value

Assign a value to the value of a mutable owned variable itself.
"""
macro set(expr)
    if !Meta.isexpr(expr, :(=))
        error("@set requires an assignment expression")
    end

    dest = expr.args[1]
    value = expr.args[2]

    return esc(:($(set_value!)($dest, $value)))
end

function cleanup!(lifetime::Lifetime)
    # Clean up immutable references
    for owner in lifetime.immutable_refs
        owner.immutable_borrows -= 1
    end
    empty!(lifetime.immutable_refs)

    # Clean up mutable references
    for owner in lifetime.mutable_refs
        owner.mutable_borrows -= 1
    end
    empty!(lifetime.mutable_refs)
end

"""
    @lifetime name begin
        @ref name(rx = x)
        @ref_mut name(ry = y)
        # use refs here
    end

Create a lifetime scope for references. References created with this lifetime
are only valid within the block and are automatically cleaned up when the block exits.
Can be used with either begin/end blocks or let blocks.
"""
macro lifetime(name, body)
    if !Meta.isexpr(body, :block) && !Meta.isexpr(body, :let)
        error("@lifetime requires a begin/end block or let block")
    end

    inner_body = if Meta.isexpr(body, :let)
        let_expr = body.args[1]
        let_body = body.args[2]
        if isempty(rmlines(let_expr).args)
            quote
                let
                    $let_body
                end
            end
        else
            quote
                let $let_expr
                    $let_body
                end
            end
        end
    else
        body
    end

    # Wrap the body in lifetime management
    return esc(quote
        let $(name) = $(Lifetime)()
            try
                $inner_body
            finally
                $(cleanup!)($(name))
            end
        end
    end)
end

"""
    @ref lifetime(var = value)

Create an immutable reference to an owned value within the given lifetime scope.
Returns a Borrowed{T} that forwards access to the underlying value.
"""
macro ref(expr)
    @assert Meta.isexpr(expr, :call)
    @assert length(expr.args) == 2
    @assert Meta.isexpr(expr.args[2], :(kw))

    name = expr.args[1]
    dest = expr.args[2].args[1]
    src = expr.args[2].args[2]
    return esc(:($dest = $(create_immutable_ref)($name, $src)))
end

function create_immutable_ref(lt::Lifetime, ref_or_owner::AllWrappers)
    is_owner = ref_or_owner isa AllOwned
    owner = is_owner ? ref_or_owner : ref_or_owner.owner

    is_owner ? Borrowed(owner, lt) : Borrowed(request_value(ref_or_owner, Val(:read)), owner, lt)
end

"""
    @ref_mut lifetime(var = value)

Create a mutable reference to an owned value within the given lifetime scope.
Returns a BorrowedMut{T} that forwards access to the underlying value.
"""
macro ref_mut(expr)
    @assert Meta.isexpr(expr, :call)
    @assert length(expr.args) == 2
    @assert Meta.isexpr(expr.args[2], :(kw))

    name = expr.args[1]
    dest = expr.args[2].args[1]
    src = expr.args[2].args[2]
    return esc(:($dest = $(BorrowedMut)($src, $name)))
end
# --- END MACROS ---

# --- GENERIC UTILITY FUNCTIONS ---
@generated function recursive_ismutable(::Union{T,Type{T}}) where {T}
    return ismutable(T) || any(recursive_ismutable, fieldtypes(T))
end
# --- END GENERIC UTILITY FUNCTIONS ---

end
