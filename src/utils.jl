# Mutability checking
@generated function recursive_ismutable(::Union{T,Type{T}}) where {T}
    return ismutabletype(T) || any(recursive_ismutable, fieldtypes(T))
end 