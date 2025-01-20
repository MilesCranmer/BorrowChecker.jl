module StaticTraitModule

"""
    is_static(x)

This trait is used to determine if we can safely
`@take!` a value without marking the original as moved.

This is somewhat analogous to the `Copy` trait in Rust,
although because Julia immutables are truly immutable,
we actually do not need to copy on these.

For the most part, this is equal to `isbits`,
but it also includes things like `Symbol` and `Type{T}`
(recursively), which are not `isbits`, but which
are immutable.
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

# COV_EXCL_START
is_static(::Type{<:Type}) = true
is_static(::Type{Symbol}) = true
is_static(::Type{String}) = true
is_static(::Type{Module}) = true
# COV_EXCL_STOP

is_static(::T) where {T} = is_static(T)

end
