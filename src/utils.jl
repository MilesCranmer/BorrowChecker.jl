module UtilsModule

# Mutability checking
@generated function recursive_ismutable(::Union{T,Type{T}}) where {T}
    return ismutabletype(T) || any(recursive_ismutable, fieldtypes(T))
end

# Analogous to `nothing` but never used to mean something
struct Unused end

end
