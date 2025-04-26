module OverloadsModule

using Random: Random, AbstractRNG
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
using ..StaticTraitModule: is_static, is_static_elements
using ..SemanticsModule: request_value, mark_moved!, validate_mode
using ..ErrorsModule: BorrowRuleError, AliasedReturnError
using ..UtilsModule: Unused, isunused, @_stable

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

function throw_view_error(op::Function, @nospecialize(r::AllWrappers))
    throw(
        BorrowRuleError(
            "Cannot create $(op) of anything other than an immutable reference, but received a `$(typeof(r))`. " *
            "You should create an immutable reference with `@ref` and then create a $(op) of that.",
        ),
    )
end
for op in (:view, :reshape, :transpose, :adjoint)
    extra_args = op in (:view, :reshape) ? (:(i...),) : ()
    @eval @_stable begin
        function Base.$(op)(r::W, $(extra_args...)) where {W<:AllWrappers{<:AbstractArray}}
            if !(W <: Union{Borrowed,LazyAccessorOf{Borrowed}})
                return throw_view_error($(op), r)
            end
            return Borrowed(
                $(op)(
                    request_value(r, Val(:read)), map(_maybe_read, ($(extra_args...),))...
                ),
                get_owner(r),
                get_lifetime(r),
            )
        end
    end
end

#! format: off

# --- BASIC OPERATIONS ---
Base.isnothing(r::AllWrappers) = isnothing(request_value(r, Val(:read)))
for op in (:(==), :isequal)
    @eval @_stable begin
        Base.$(op)(r::AllWrappers, other) = $(op)(request_value(r, Val(:read)), other)
        Base.$(op)(other, r::AllWrappers) = $(op)(other, request_value(r, Val(:read)))
        Base.$(op)(r::AllWrappers, other::AllWrappers) = $(op)(request_value(r, Val(:read)), request_value(other, Val(:read)))
    end
end
Base.haskey(r::AllWrappers, other) = haskey(request_value(r, Val(:read)), _maybe_read(other))
Base.string(r::AllWrappers) = string(request_value(r, Val(:read)))
Base.hash(r::AllWrappers, h::UInt) = hash(request_value(r, Val(:read)), h)
for op in (:rand, :randn)
    @eval @_stable begin
        # We don't define methods without `rng` since:
        #   1. The ambiguities are a mess.
        #   2. The user should be encouraged to `@own` the rng.
        function Base.$(op)(rng::AllWrappers{<:AbstractRNG}, d::Integer, dims::Integer...)
            return $(op)(request_value(rng, Val(:write)), d, dims...)
        end
        function Base.$(op)(rng::AllWrappers{<:AbstractRNG}, d::AllWrappers{<:Integer}, dims::Union{Integer,AllWrappers{<:Integer}}...)
            return $(op)(request_value(rng, Val(:write)), map(_maybe_read, (d, dims...))...)
        end
        function Base.$(op)(rng::AllWrappers{<:AbstractRNG}, ::Type{T}, d::Integer, dims::Integer...) where {T}
            return $(op)(request_value(rng, Val(:write)), T, d, dims...)
        end
        function Base.$(op)(rng::AllWrappers{<:AbstractRNG}, ::Type{T}, d::AllWrappers{<:Integer}, dims::Union{Integer,AllWrappers{<:Integer}}...) where {T}
            return $(op)(request_value(rng, Val(:write)), T, map(_maybe_read, (d, dims...))...)
        end
    end
end
# --- END BASIC OPERATIONS ---

# --- COLLECTION OPERATIONS ---

# ---- Non-mutating; safe to return ----
for op in (
    :length, :isempty, :size, :axes, :firstindex, :lastindex,
    :eachindex, :any, :all, :ndims, :eltype, :strides,
    :issorted, :keytype, :valtype
)
    @eval @_stable Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:read)))
end
Base.size(r::AllWrappers, i) = size(request_value(r, Val(:read)), _maybe_read(i))
Base.in(item, collection::AllWrappers) = in(item, request_value(collection, Val(:read)))
Base.in(item::AllWrappers, collection::AllWrappers) = in(request_value(item, Val(:read)), request_value(collection, Val(:read)))
Base.count(f, r::AllWrappers) = count(f, request_value(r, Val(:read)))

# ---- Non-mutating; possibly unsafe to return ----
# 1 arg
for op in (
    :keys, :values, :pairs, :unique, :sort, :reverse,
    :sum, :prod, :maximum, :minimum, :extrema,
    :copy, :collect,
)
    @eval @_stable function Base.$(op)(r::AllWrappers; kws...)
        out = $(op)(request_value(r, Val(:read)); kws...)
        if !is_static_elements(out)
            throw(AliasedReturnError($(op), typeof(out), 1))
        end
        return out
    end
end
# 2 args
for op in (
    :union, :intersect, :setdiff, :symdiff, :merge
)
    @eval @_stable function Base.$(op)(x::AllWrappers, y::AllWrappers)
        out = $(op)(request_value(x, Val(:read)), request_value(y, Val(:read)))
        if !is_static_elements(out)
            throw(AliasedReturnError($(op), typeof(out), 2))
        end
        return out
    end
end


# ---- Non-mutating; unsafe to return ----
Base.sizehint!(r::AllWrappers, n) = (sizehint!(request_value(r, Val(:read)), _maybe_read(n)); nothing)

# ---- Mutating; safe to return ----
# These are safe to return, because the value is inaccessible from
# the original owner.
for op in (:pop!, :popfirst!)
    @eval @_stable Base.$(op)(r::AllWrappers) = $(op)(request_value(r, Val(:write)))
end
Base.pop!(r::AllWrappers, k) = pop!(request_value(r, Val(:write)), _maybe_read(k))

# ---- Mutating; unsafe to return ----
# These return a new reference to the passed object which is not safe,
# so either the user needs to keep the variable around, or use `@take!`.
for op in (:push!, :append!)
    @eval @_stable Base.$(op)(r::AllWrappers, items...) = ($(op)(request_value(r, Val(:write)), items...); nothing)
end
Base.resize!(r::AllWrappers, n::Integer) = (resize!(request_value(r, Val(:write)), _maybe_read(n)); nothing)
Base.copyto!(dest::AllWrappers, src) = (copyto!(request_value(dest, Val(:write)), src); nothing)
Base.copyto!(dest::AllWrappers, src::AllWrappers) = (copyto!(request_value(dest, Val(:write)), request_value(src, Val(:read))); nothing)
Base.copyto!(dest::AbstractArray, src::AllWrappers) = (copyto!(dest, request_value(src, Val(:read))); nothing)
for op in (:empty!, :sort!, :reverse!, :unique!)
    @eval @_stable Base.$(op)(r::AllWrappers) = ($(op)(request_value(r, Val(:write))); nothing)
end
Random.shuffle!(rng::AbstractRNG, r::AllWrappers) = (Random.shuffle!(rng, request_value(r, Val(:write))); nothing)
Random.shuffle!(r::AllWrappers) = Random.shuffle!(Random.default_rng(), r)

# Using an RNG is a write operation!
Random.shuffle!(rng::AllWrappers{<:AbstractRNG}, r::AllWrappers) = Random.shuffle!(request_value(rng, Val(:write)), r)

# ---- Other ----
# TODO: Add `insert!` and `delete!`
function Base.iterate(::Union{AllOwned,LazyAccessorOf{AllOwned}})
    error("Use `@own for var in iter` (moves) or `@ref for var in iter` (borrows) instead.")
end
function Base.iterate(r::Union{Borrowed,LazyAccessorOf{Borrowed}}, state=Unused())
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
# TODO: This is not safe for non-static values
Base.getindex(r::AllWrappers{<:AbstractDict}, key) = getindex(request_value(r, Val(:read)), _maybe_read(key))
Base.delete!(r::AllWrappers{<:AbstractDict}, key) = (delete!(request_value(r, Val(:write)), _maybe_read(key)); nothing)
# --- END DICTIONARY OPERATIONS ---

# --- STRING OPERATIONS ---
Base.ncodeunits(r::AllWrappers{<:AbstractString}) = ncodeunits(request_value(r, Val(:read)))
for op in (:startswith, :endswith)
    @eval @_stable begin
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
    # Math
    :sin, :cos, :tan, :sinh, :cosh, :tanh, :asin, :acos,
    :asinh, :acosh, :atanh, :sec, :csc, :cot, :asec, :acsc, :acot, :sech, :csch,
    :coth, :asech, :acsch, :acoth, :sinc, :cosc, :cosd, :cotd, :cscd, :secd,
    :sinpi, :cospi, :sind, :tand, :acosd, :acotd, :acscd, :asecd, :asind,
    :log, :log2, :log10, :log1p, :exp, :exp2, :exp10, :expm1, :frexp, :exponent,
    :float, :abs, :real, :imag, :conj, :transpose, :significand,
    :modf, :rem, :floor, :ceil, :round, :trunc,
    :inv, :sqrt, :cbrt, :abs2, :angle, :factorial,
    :(!), :-, :+, :sign, :identity, :iszero, :isone,
    # Instantiation
    :signed, :unsigned, :widen, :prevfloat, :nextfloat,
    :one, :oneunit, :zero, :typemin, :typemax, :eps,
)
    @eval @_stable function Base.$(op)(r::AllWrappers{<:Number})
        return Base.$(op)(request_value(r, Val(:read)))
    end
end
# 2 args
for op in (
    :*, :/, :+, :-, :^, :÷, :mod, :log,
    :atan, :atand, :copysign, :flipsign,
    :&, :|, :⊻, ://, :\, :(:), :rem, :cmp,
    :isapprox, :(<), :(<=), :(>), :(>=), :isless,
    :(<<), :(>>), :(>>>),
)
    # TODO: Forward kwargs
    @eval @_stable begin
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
    @eval @_stable begin
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
