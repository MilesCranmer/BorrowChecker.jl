module BorrowChecker

using MacroTools
using MacroTools: rmlines

export @own, @move, @ref, @take, @set, @lifetime
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

function Base.showerror(io::IO, e::MovedError)
    return print(io, "Cannot use $(e.var): value has been moved")
end
Base.showerror(io::IO, e::BorrowRuleError) = print(io, e.msg)
# --- END ERROR TYPES ---

# --- CORE TYPES ---
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
        throw(MovedError(r.symbol))
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
        throw(MovedError(owner.symbol))
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
        throw(MovedError(r.symbol))
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
    if name in (:moved, :immutable_borrows, :mutable_borrows, :symbol)
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
function Base.getindex(r::Borrowed{<:AbstractArray{T}}, i...) where {T}
    return Borrowed(getindex(request_value(r, Val(:read)), i...), r.owner, r.lifetime)
end

Base.length(r::AllWrappers) = length(request_value(r, Val(:read)))
Base.size(r::AllWrappers) = size(request_value(r, Val(:read)))
Base.axes(r::AllWrappers) = axes(request_value(r, Val(:read)))
Base.firstindex(r::AllWrappers) = firstindex(request_value(r, Val(:read)))
Base.lastindex(r::AllWrappers) = lastindex(request_value(r, Val(:read)))

# Forward comparison to the underlying value
Base.:(==)(r::AllWrappers, other) = request_value(r, Val(:read)) == other
Base.:(==)(other, r::AllWrappers) = other == request_value(r, Val(:read))
function Base.:(==)(r::AllWrappers, other::AllWrappers)
    return request_value(r, Val(:read)) == request_value(other, Val(:read))
end

# Forward array operations for mutable wrappers
Base.push!(r::AllWrappers, items...) = (push!(request_value(r, Val(:write)), items...); r)
Base.append!(r::AllWrappers, items) = (append!(request_value(r, Val(:write)), items); r)
Base.pop!(r::AllWrappers) = (pop!(request_value(r, Val(:write))); r)
Base.popfirst!(r::AllWrappers) = (popfirst!(request_value(r, Val(:write))); r)
Base.empty!(r::AllWrappers) = (empty!(request_value(r, Val(:write))); r)
Base.resize!(r::AllWrappers, n) = (resize!(request_value(r, Val(:write)), n); r)
# --- END CONTAINER OPERATIONS ---

# --- MATH OPERATIONS ---

# Binary operators
#! format: off
for op in (
    :*, :/, :+, :-, :^, :÷, :mod, :log,
    :atan, :atand, :copysign, :flipsign,
    :&, :|, :⊻, ://, :\,
)
    @eval begin
        function Base.$(op)(l::Number, r::AllWrappers{<:Number})
            return Base.$(op)(l, request_value(r, Val(:read)))
        end
        function Base.$(op)(l::AllWrappers{<:Number}, r::Number)
            return Base.$(op)(request_value(l, Val(:read)), r)
        end
        function Base.$(op)(l::AllWrappers{<:Number}, r::AllWrappers{<:Number})
            return Base.$(op)(request_value(l, Val(:read)), request_value(r, Val(:read)))
        end
    end
end
for op in (
    :sin, :cos, :tan, :sinh, :cosh, :tanh, :asin, :acos,
    :asinh, :acosh, :atanh, :sec, :csc, :cot, :asec, :acsc, :acot, :sech, :csch,
    :coth, :asech, :acsch, :acoth, :sinc, :cosc, :cosd, :cotd, :cscd, :secd,
    :sinpi, :cospi, :sind, :tand, :acosd, :acotd, :acscd, :asecd, :asind,
    :log, :log2, :log10, :log1p, :exp, :exp2, :exp10, :expm1, :frexp, :exponent,
    :float, :abs, :real, :imag, :conj, :unsigned,
    :nextfloat, :prevfloat, :transpose, :significand,
    :modf, :rem, :floor, :ceil, :round, :trunc,
    :inv, :sqrt, :cbrt, :abs2, :angle, :factorial,
    :(!), :-, :+, :sign, :identity,
)
    @eval function Base.$(op)(r::AllWrappers{<:Number})
        return Base.$(op)(request_value(r, Val(:read)))
    end
end
#! format: on
# --- END MATH OPERATIONS ---

# TODO: Add other interfaces

# --- MACROS ---
"""
    @own const x = value
    @own x = value

Create a new owned value. If `const` is specified, the value will be immutable.
Otherwise, the value will be mutable.
"""
macro own(expr)
    if Meta.isexpr(expr, :const)
        # Handle const case
        if !Meta.isexpr(expr.args[1], :(=))
            error("@own const requires an assignment expression")
        end
        name = expr.args[1].args[1]
        value = expr.args[1].args[2]
        return esc(:($(name) = Owned($(value), false, $(QuoteNode(name)))))
    elseif Meta.isexpr(expr, :(=))
        # Handle non-const case
        name = expr.args[1]
        value = expr.args[2]
        return esc(:($(name) = OwnedMut($(value), false, $(QuoteNode(name)))))
    else
        error("@own requires an assignment expression")
    end
end

"""
    @move const new = old
    @move new = old

Transfer ownership from one variable to another, invalidating the old variable.
If `const` is specified, the destination will be immutable.
Otherwise, the destination will be mutable.
"""
macro move(expr)
    if Meta.isexpr(expr, :const)
        # Handle const case
        if !Meta.isexpr(expr.args[1], :(=))
            error("@move const requires an assignment expression")
        end
        dest = expr.args[1].args[1]
        src = expr.args[1].args[2]
        value = gensym(:value)

        return esc(
            quote
                $value = $(request_value)($src, Val(:read))
                $dest = Owned($value, false, $(QuoteNode(dest)))
                $(mark_moved!)($src)
                $dest
            end,
        )
    elseif Meta.isexpr(expr, :(=))
        # Handle non-const case
        dest = expr.args[1]
        src = expr.args[2]
        value = gensym(:value)

        return esc(
            quote
                $value = $(request_value)($src, Val(:read))
                $dest = OwnedMut($value, false, $(QuoteNode(dest)))
                $(mark_moved!)($src)
                $dest
            end,
        )
    else
        error("@move requires an assignment expression")
    end
end

"""
    @take var

Take ownership of a value, typically used in function arguments.
Returns the inner value and marks the original as moved.
"""
macro take(var)
    value = gensym(:value)
    return esc(
        quote
            $value = $(request_value)($var, $(Val(:read)))
            $(mark_moved!)($var)
            $value
        end,
    )
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
    return empty!(lifetime.mutable_refs)
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
    return esc(
        quote
            let $(name) = $(Lifetime)()
                try
                    $inner_body
                finally
                    $(cleanup!)($(name))
                end
            end
        end,
    )
end

"""
    @ref const var = value in lifetime
    @ref var = value in lifetime

Create a reference to an owned value within the given lifetime scope.
If `const` is specified, creates an immutable reference.
Otherwise, creates a mutable reference.
Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.
"""
macro ref(expr)
    if Meta.isexpr(expr, :const)
        # Handle const case
        if !Meta.isexpr(expr.args[1], :(=))
            error("@ref const requires an assignment expression")
        end
        dest = expr.args[1].args[1]
        if !Meta.isexpr(expr.args[1].args[2], :call) || expr.args[1].args[2].args[1] != :in
            error("@ref const requires 'in' syntax: @ref const var = value in lifetime")
        end
        src = expr.args[1].args[2].args[2]
        lifetime = expr.args[1].args[2].args[3]
        return esc(:($dest = $(create_immutable_ref)($lifetime, $src)))
    elseif Meta.isexpr(expr, :(=))
        # Handle non-const case
        dest = expr.args[1]
        if !Meta.isexpr(expr.args[2], :call) || expr.args[2].args[1] != :in
            error("@ref requires 'in' syntax: @ref var = value in lifetime")
        end
        src = expr.args[2].args[2]
        lifetime = expr.args[2].args[3]
        return esc(:($dest = $(BorrowedMut)($src, $lifetime)))
    else
        error("@ref requires an assignment expression")
    end
end

function create_immutable_ref(lt::Lifetime, ref_or_owner::AllWrappers)
    # TODO: Put this in `Borrowed`

    is_owner = ref_or_owner isa AllOwned
    owner = is_owner ? ref_or_owner : ref_or_owner.owner

    if !is_owner
        @assert(
            ref_or_owner.lifetime === lt,
            "Lifetime mismatch! Nesting lifetimes is not allowed."
        )
    end

    if is_owner
        return Borrowed(owner, lt)
    else
        return Borrowed(request_value(ref_or_owner, Val(:read)), owner, lt)
    end
end
# --- END MACROS ---

# --- GENERIC UTILITY FUNCTIONS ---
@generated function recursive_ismutable(::Union{T,Type{T}}) where {T}
    return ismutabletype(T) || any(recursive_ismutable, fieldtypes(T))
end
# --- END GENERIC UTILITY FUNCTIONS ---

end
