module StaticTraitModule

"""
    is_static(x)

Approximation of the `Copy` trait in Rust.

For the most part, this is equivalent to `isbits`,
but it also includes things like `Symbol` and `Type{T}`
(recursively), which are not `isbits`.
"""
function is_static(::Type{T}) where {T}
    if isbitstype(T)
        return true
    elseif T isa UnionAll || T === Union{}
        return false
    elseif isstructtype(T) && ismutabletype(T)
        return false
    elseif T isa Union
        return is_static(T.a) && is_static(T.b)
    elseif !(T isa DataType)
        return false
    elseif Base.datatype_fieldcount(T) === nothing
        return false
    else
        return all(is_static, fieldtypes(T))
    end
end
function is_static(::Type{<:Type})
    return true
end
function is_static(::Type{Symbol})
    return true
end
function is_static(::T) where {T}
    return is_static(T)
end

end
