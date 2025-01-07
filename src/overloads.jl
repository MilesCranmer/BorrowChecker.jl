module OverloadsModule

using ..TypesModule:
    Bound,
    BoundMut,
    Borrowed,
    BorrowedMut,
    AllOwned,
    AllBorrowed,
    AllWrappers,
    constructorof
using ..SemanticsModule: request_value, mark_moved!
using ..ErrorsModule: BorrowRuleError
using ..UtilsModule: recursive_ismutable, Unused

# Container operations
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
function Base.getindex(r::BorrowedMut{<:AbstractArray{T}}, i...) where {T}
    if recursive_ismutable(T) ||
        !((return_value = getindex(request_value(r, Val(:read)), i...)) isa T)
        # TODO: Make this more generic
        throw(BorrowRuleError("Cannot create slice of a mutable borrowed array"))
    end
    # Only allowed to return single immutable values
    return return_value
end

#! format: off

# --- BASIC OPERATIONS ---
Base.haskey(r::AllWrappers, key) = haskey(request_value(r, Val(:read)), key)
Base.:(==)(r::AllWrappers, other) = request_value(r, Val(:read)) == other
Base.:(==)(other, r::AllWrappers) = other == request_value(r, Val(:read))
Base.:(==)(r::AllWrappers, other::AllWrappers) = request_value(r, Val(:read)) == request_value(other, Val(:read))
for op in (:hash, :string)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
function Base.promote_rule(::Type{<:AllWrappers}, ::Type)
    # We never want to convert an owned or borrowed object, so
    # we refuse to define a common promotion rule.
    return Any
end
# --- END BASIC OPERATIONS ---

# --- COLLECTION OPERATIONS ---
# Basic collection operations
for op in (:length, :isempty, :size, :axes, :firstindex, :lastindex, :eachindex)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
Base.size(r::AllWrappers, i) = size(request_value(r, Val(:read)), i)
for op in (:pop!, :popfirst!, :empty!, :resize!)
    @eval Base.$(op)(r::AllWrappers) = ($(op)(request_value(r, Val(:write))); r)
end
for op in (:push!, :append!)
    @eval Base.$(op)(r::AllWrappers, items...) = ($(op)(request_value(r, Val(:write)), items...); r)
end
function Base.iterate(::AllOwned)
    error("Cannot yet iterate over owned arrays. Iterate over a `@ref const` instead.")
end
function Base.iterate(r::Borrowed, state=Unused())
    out = iterate(request_value(r, Val(:read)), (state isa Unused ? () : (state,))...)
    out === nothing && return nothing
    (iter, state) = out
    return (Borrowed(iter, r.owner, r.lifetime), state)
end
function Base.iterate(::BorrowedMut{<:AbstractArray{T}}) where {T}
    error("Cannot yet iterate over mutable borrowed arrays. Iterate over a `@ref const` instead.")
end
# --- END COLLECTION OPERATIONS ---

# --- DICTIONARY OPERATIONS ---

# --- END DICTIONARY OPERATIONS ---

# --- STRING OPERATIONS ---
Base.ncodeunits(r::AllWrappers{<:AbstractString}) = ncodeunits(request_value(r, Val(:read)))
for op in (:startswith, :endswith)
    @eval begin
        # both args
        Base.$(op)(r::AllWrappers{<:AbstractString}, s::AllWrappers{<:AbstractString}) = $(op)(request_value(r, Val(:read)), request_value(s, Val(:read)))
        # one arg
        Base.$(op)(r::AllWrappers{<:AbstractString}, s) = $(op)(request_value(r, Val(:read)), s)
        Base.$(op)(r::AbstractString, s::AllWrappers{<:AbstractString}) = $(op)(r, request_value(s, Val(:read)))
    end
end
# --- END STRING OPERATIONS ---

# --- NUMBER OPERATIONS ---
# 1 arg
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
# 2 args
for op in (
    :*, :/, :+, :-, :^, :÷, :mod, :log,
    :atan, :atand, :copysign, :flipsign,
    :&, :|, :⊻, ://, :\, :(:), :rem, :cmp,
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
# 3 args
for op in (:(:), :clamp, :fma, :muladd)
    @eval begin
        # all
        function Base.$(op)(l::AllWrappers{<:Number}, m::AllWrappers{<:Number}, r::AllWrappers{<:Number})
            return Base.$(op)(request_value(l, Val(:read)), request_value(m, Val(:read)), request_value(r, Val(:read)))
        end
        # 2 args
        function Base.$(op)(l::AllWrappers{<:Number}, m::AllWrappers{<:Number}, r::Number)
            return Base.$(op)(request_value(l, Val(:read)), request_value(m, Val(:read)), r)
        end
        function Base.$(op)(l::AllWrappers{<:Number}, m::Number, r::AllWrappers{<:Number})
            return Base.$(op)(request_value(l, Val(:read)), m, request_value(r, Val(:read)))
        end
        function Base.$(op)(l::Number, m::AllWrappers{<:Number}, r::AllWrappers{<:Number})
            return Base.$(op)(l, request_value(m, Val(:read)), request_value(r, Val(:read)))
        end
        # 1 arg
        function Base.$(op)(l::AllWrappers{<:Number}, m::Number, r::Number)
            return Base.$(op)(request_value(l, Val(:read)), m, r)
        end
        function Base.$(op)(l::Number, m::AllWrappers{<:Number}, r::Number)
            return Base.$(op)(l, request_value(m, Val(:read)), r)
        end
        function Base.$(op)(l::Number, m::Number, r::AllWrappers{<:Number})
            return Base.$(op)(l, m, request_value(r, Val(:read)))
        end
    end
end
# --- END NUMBER OPERATIONS ---

#! format: on

end
