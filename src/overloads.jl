module OverloadsModule

using ..TypesModule:
    Owned,
    OwnedMut,
    Borrowed,
    BorrowedMut,
    AllOwned,
    AllBorrowed,
    AllEager,
    AllWrappers,
    LazyAccessor,
    LazyAccessorOf,
    constructorof,
    unsafe_access,
    get_owner,
    get_lifetime
using ..StaticTraitModule: is_static
using ..SemanticsModule: request_value, mark_moved!, validate_mode
using ..ErrorsModule: BorrowRuleError
using ..UtilsModule: Unused, isunused

_maybe_read(x) = x
_maybe_read(x::AllWrappers) = request_value(x, Val(:read))

# Container operations
function Base.getindex(o::AllEager{A}, i...) where {T,A<:Union{Ref{T},AbstractArray{T}}}
    if is_static(T)
        return getindex(request_value(o, Val(:read)), map(_maybe_read, i)...)
    else
        return LazyAccessor(o, (map(_maybe_read, i)...,))
    end
end
function Base.getindex(o::AllEager{A}, i) where {A<:Tuple}
    out = getindex(request_value(o, Val(:read)), _maybe_read(i))
    if is_static(out)
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

function Base.view(::AllOwned{A}, i...) where {A<:Union{AbstractArray,Tuple}}
    throw(
        BorrowRuleError(
            "Cannot create view of an owned object. " *
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
for op in (:(==), :isequal)
    @eval begin
        Base.$(op)(r::AllWrappers, other) = $(op)(request_value(r, Val(:read)), other)
        Base.$(op)(other, r::AllWrappers) = $(op)(other, request_value(r, Val(:read)))
        Base.$(op)(r::AllWrappers, other::AllWrappers) = $(op)(request_value(r, Val(:read)), request_value(other, Val(:read)))
    end
end
Base.haskey(r::AllWrappers, other) = haskey(request_value(r, Val(:read)), _maybe_read(other))
Base.string(r::AllWrappers) = string(request_value(r, Val(:read)))
Base.hash(r::AllWrappers, h::UInt) = hash(request_value(r, Val(:read)), h)
# --- END BASIC OPERATIONS ---

# --- COLLECTION OPERATIONS ---

# ---- Non-mutating; safe to return ----
for op in (
    :length, :isempty, :size, :axes, :firstindex, :lastindex,
    :eachindex, :any, :all, :ndims, :eltype, :strides,
)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
Base.size(r::AllWrappers, i) = size(request_value(r, Val(:read)), _maybe_read(i))

# ---- Non-mutating; possibly unsafe to return ----
for op in (
    :keys, :values, :unique, :sort, :reverse,
    :sum, :prod, :maximum, :minimum, :extrema,
    :copy
)
    @eval function Base.$(op)(r::AllWrappers; kws...)
        k = $(op)(request_value(r, Val(:read)); kws...)
        if !is_static(eltype(k))
            error(
                "Refusing to return result of " * string($(op)) *
                " with a non-isbits element type, because this can result in unintended aliasing with the original array. " *
                "Use `" * string($(op)) * "(@take!(d))` instead."
            )
        end
        return k
    end
end

# ---- Non-mutating; unsafe to return ----
Base.sizehint!(r::AllWrappers, n) = (sizehint!(request_value(r, Val(:read)), _maybe_read(n)); nothing)

# ---- Mutating; safe to return ----
# These are safe to return, because the value is inaccessible from
# the original owner.
for op in (:pop!, :popfirst!)
    @eval Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:write)))
end
Base.pop!(r::AllWrappers, k) = pop!(request_value(r, Val(:write)), _maybe_read(k))

# ---- Mutating; unsafe to return ----
# These return a new reference to the passed object which is not safe,
# so either the user needs to keep the variable around, or use `@take!`.
for op in (:push!, :append!)
    @eval Base.$(op)(r::AllWrappers, items...) = ($(op)(request_value(r, Val(:write)), items...); nothing)
end
Base.resize!(r::AllWrappers, n::Integer) = (resize!(request_value(r, Val(:write)), _maybe_read(n)); nothing)
for op in (:empty!, :sort!, :reverse!)
    @eval Base.$(op)(r::AllWrappers) = ($(op)(request_value(r, Val(:write))); nothing)
end

# ---- Other ----
# TODO: Add `insert!` and `delete!`
function Base.iterate(::Union{AllOwned,LazyAccessorOf{<:AllOwned}})
    error("Use `@own for var in iter` (moves) or `@ref for var in iter` (borrows) instead.")
end
function Base.iterate(r::Union{Borrowed,LazyAccessorOf{<:Borrowed}}, state=Unused())
    out = iterate(request_value(r, Val(:read)), (isunused(state) ? () : (state,))...)
    out === nothing && return nothing
    (iter, state) = out
    return (Borrowed(iter, get_owner(r), get_lifetime(r)), state)
end
function Base.iterate(::Union{BorrowedMut{<:AbstractArray{T}},LazyAccessorOf{<:BorrowedMut{<:AbstractArray{T}}}}, state=Unused()) where {T}
    error("Cannot yet iterate over mutable borrowed arrays. Iterate over a `@ref` instead.")
end
# TODO: Double check semantics of this
function Base.copy!(r::AllWrappers, src::AllWrappers)
    src_value = request_value(src, Val(:read))
    copy!(request_value(r, Val(:write)), is_static(eltype(src_value)) ? src_value : deepcopy(src_value))
    return nothing
end
# --- END COLLECTION OPERATIONS ---

# --- DICTIONARY OPERATIONS ---
# Dictionary-specific operations
Base.getindex(r::AllWrappers{<:AbstractDict}, key) = getindex(request_value(r, Val(:read)), _maybe_read(key))
Base.delete!(r::AllWrappers{<:AbstractDict}, key) = (delete!(request_value(r, Val(:write)), _maybe_read(key)); nothing)
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
    :(!), :-, :+, :sign, :identity, :iszero, :isone,
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
    :(<<), :(>>), :(>>>),
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
