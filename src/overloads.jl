module OverloadsModule

using ..TypesModule:
    Owned,
    OwnedMut,
    Borrowed,
    BorrowedMut,
    AllOwned,
    AllBorrowed,
    AllWrappers,
    constructorof
using ..SemanticsModule: request_value, mark_moved!
using ..ErrorsModule: BorrowRuleError
using ..UtilsModule: recursive_ismutable

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

# --- COLLECTION OPERATIONS ---
# Basic collection operations
Base.length(r::AllWrappers) = length(request_value(r, Val(:read)))
Base.size(r::AllWrappers) = size(request_value(r, Val(:read)))
Base.size(r::AllWrappers, i) = size(request_value(r, Val(:read)), i)
Base.axes(r::AllWrappers) = axes(request_value(r, Val(:read)))
Base.firstindex(r::AllWrappers) = firstindex(request_value(r, Val(:read)))
Base.lastindex(r::AllWrappers) = lastindex(request_value(r, Val(:read)))
Base.eachindex(r::AllWrappers) = eachindex(request_value(r, Val(:read)))

# Forward array operations for mutable wrappers
Base.push!(r::AllWrappers, items...) = (push!(request_value(r, Val(:write)), items...); r)
Base.append!(r::AllWrappers, items) = (append!(request_value(r, Val(:write)), items); r)
Base.pop!(r::AllWrappers) = (pop!(request_value(r, Val(:write))); r)
Base.popfirst!(r::AllWrappers) = (popfirst!(request_value(r, Val(:write))); r)
Base.empty!(r::AllWrappers) = (empty!(request_value(r, Val(:write))); r)
Base.resize!(r::AllWrappers, n) = (resize!(request_value(r, Val(:write)), n); r)
# --- END COLLECTION OPERATIONS ---

# --- COMPARISON OPERATIONS ---
Base.:(==)(r::AllWrappers, other) = request_value(r, Val(:read)) == other
Base.:(==)(other, r::AllWrappers) = other == request_value(r, Val(:read))
Base.:(==)(r::AllWrappers, other::AllWrappers) = request_value(r, Val(:read)) == request_value(other, Val(:read))
# --- END COMPARISON OPERATIONS ---

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
    :&, :|, :⊻, ://, :\, :(:), :rem
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
