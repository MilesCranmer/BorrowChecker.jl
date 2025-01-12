module OverloadsModule

using ..TypesModule:
    Bound,
    BoundMut,
    Borrowed,
    BorrowedMut,
    AllBound,
    AllBorrowed,
    AllEager,
    AllWrappers,
    LazyAccessor,
    LazyAccessorOf,
    constructorof,
    unsafe_access,
    get_owner,
    get_lifetime
using ..SemanticsModule: request_value, mark_moved!, validate_mode
using ..ErrorsModule: BorrowRuleError
using ..UtilsModule: Unused

_maybe_read(x) = x
_maybe_read(x::AllWrappers) = request_value(x, Val(:read))

# Container operations
function Base.getindex(o::AllEager{A}, i...) where {T,A<:Union{Ref{T},AbstractArray{T}}}
    if isbitstype(T)
        return getindex(request_value(o, Val(:read)), map(_maybe_read, i)...)
    else
        return LazyAccessor(o, (map(_maybe_read, i)...,))
    end
end
function Base.getindex(o::AllEager{A}, i) where {A<:Tuple}
    out = getindex(request_value(o, Val(:read)), _maybe_read(i))
    if isbits(out)
        return out
    else
        return LazyAccessor(o, (i,))
    end
end
function Base.getindex(r::LazyAccessor, i...)
    return LazyAccessor(r, (map(_maybe_read, i)...,))
end
function Base.setindex!(r::AllEager, value, i...)
    setindex!(request_value(r, Val(:write)), value, map(_maybe_read, i)...)
    # TODO: This is not good Julia style, but otherwise we would
    #       need to return a new owned object. We have to break
    #       a lot of conventions here for safety.
    return nothing
end
function Base.setindex!(r::LazyAccessor, value, i...)
    owner = getfield(r, :target)
    validate_mode(owner, Val(:write))
    setindex!(unsafe_access(r), value, map(_maybe_read, i)...)
    return nothing
end

function Base.view(::AllBound{A}, i...) where {A<:Union{AbstractArray,Tuple}}
    throw(
        BorrowRuleError(
            "Cannot create view of a bound object. " *
            "You can create an immutable reference with `@ref` and then create a view of that.",
        ),
    )
end
function Base.view(
    r::Union{Borrowed{A},LazyAccessor{A,<:Any,<:Any,<:Borrowed}}, i...
) where {A<:Union{AbstractArray,Tuple}}
    return Borrowed(
        view(request_value(r, Val(:read)), map(_maybe_read, i)...),
        get_owner(r),
        get_lifetime(r),
    )
end

#! format: off

# --- BASIC OPERATIONS ---
Base.isnothing(r::AllWrappers) = isnothing(request_value(r, Val(:read)))
for op in (:(==), :haskey, :isequal)
    @eval begin
        Base.$(op)(r::AllWrappers, other) = $(op)(request_value(r, Val(:read)), other)
        Base.$(op)(other, r::AllWrappers) = $(op)(other, request_value(r, Val(:read)))
        Base.$(op)(r::AllWrappers, other::AllWrappers) = $(op)(request_value(r, Val(:read)), request_value(other, Val(:read)))
    end
end
for op in (:hash, :string)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
function Base.promote_rule(::Type{<:AllWrappers}, ::Type)
    # We never want to convert an bound or borrowed object, so
    # we refuse to define a common promotion rule.
    return Any
end
# --- END BASIC OPERATIONS ---

# --- COLLECTION OPERATIONS ---
# Basic collection operations
for op in (:length, :isempty, :size, :axes, :firstindex, :lastindex, :eachindex)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
function Base.keys(r::AllWrappers)
    value = request_value(r, Val(:read))
    k = keys(value)
    if !isbitstype(eltype(k))
        error("Refusing to return non-isbits keys of a collection. Use `keys(@take!(d))` if needed.")
    end
    return k
end
Base.size(r::AllWrappers, i) = size(request_value(r, Val(:read)), _maybe_read(i))
for op in (:pop!, :popfirst!, :empty!, :resize!)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:write)))
end
Base.pop!(r::AllWrappers, k) = pop!(request_value(r, Val(:write)), _maybe_read(k))
for op in (:push!, :append!)
    @eval Base.$(op)(r::AllWrappers, items...) = ($(op)(request_value(r, Val(:write)), items...); nothing)
end
function Base.iterate(::Union{AllBound,LazyAccessorOf{<:AllBound}})
    error("Use `@bind for var in iter` instead.")
end
function Base.iterate(r::Union{Borrowed,LazyAccessorOf{<:Borrowed}}, state=Unused())
    out = iterate(request_value(r, Val(:read)), (state isa Unused ? () : (state,))...)
    out === nothing && return nothing
    (iter, state) = out
    return (Borrowed(iter, get_owner(r), get_lifetime(r)), state)
end
function Base.iterate(::Union{BorrowedMut{<:AbstractArray{T}},LazyAccessorOf{<:BorrowedMut{<:AbstractArray{T}}}}, state=Unused()) where {T}
    error("Cannot yet iterate over mutable borrowed arrays. Iterate over a `@ref` instead.")
end
function Base.copy!(r::AllWrappers, src::AllWrappers)
    copy!(request_value(r, Val(:write)), request_value(src, Val(:read)))
    return nothing
end
# --- END COLLECTION OPERATIONS ---

# --- DICTIONARY OPERATIONS ---
# Dictionary-specific operations
Base.getindex(r::AllWrappers{<:AbstractDict}, key) = getindex(request_value(r, Val(:read)), _maybe_read(key))
Base.delete!(r::AllWrappers{<:AbstractDict}, key) = delete!(request_value(r, Val(:write)), _maybe_read(key))
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
    :isapprox, :(<), :(<=), :(>), :(>=),
)
    # TODO: Forward kwargs
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
