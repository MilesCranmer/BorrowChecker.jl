module TypeOverloadsModule

using ..TypesModule: AllWrappers

#! format: off


# These overloads are not technically correct, but they are designed
# to preserve the user's intention when using owned and borrowed types.
# One of these objects should be treated as similarly as possible to the
# type it is wrapping. So these overloads are designed to do just that.

for op in (
    # Types
    :eltype, :valtype, :keytype,
    # Type hierarchy
    :signed, :unsigned, :widen,
    # Broadcasting
    :BroadcastStyle, :IteratorSize, :IteratorEltype, :IndexStyle,
    # Instantiation
    :one, :oneunit, :zero, :typemin, :typemax, :eps,
)
    @eval Base.$(op)(::Type{<:AllWrappers{T}}) where {T} = Base.$(op)(T)
end


#! format: on

end
