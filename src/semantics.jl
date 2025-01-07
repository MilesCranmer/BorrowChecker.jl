module SemanticsModule

using ..TypesModule:
    Owned,
    OwnedMut,
    Borrowed,
    BorrowedMut,
    AllOwned,
    AllBorrowed,
    AllWrappers,
    AllMutable,
    AllImmutable,
    constructorof,
    is_mutable,
    mark_moved!,
    is_moved,
    unsafe_get_value
using ..ErrorsModule: MovedError, BorrowRuleError
using ..UtilsModule: recursive_ismutable

# Internal getters and setters

function request_value(r::AllOwned, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    if is_moved(r)
        throw(MovedError(r.symbol))
    elseif is_mutable(r) && r.mutable_borrows > 0
        throw(BorrowRuleError("Cannot access original while mutably borrowed"))
    elseif mode == :write
        if !is_mutable(r)
            throw(BorrowRuleError("Cannot write to immutable"))
        elseif r.immutable_borrows > 0
            throw(BorrowRuleError("Cannot write to original while immutably borrowed"))
        end
    end
    return unsafe_get_value(r)
end
function request_value(r::AllBorrowed, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    owner = r.owner
    if is_moved(owner)
        throw(MovedError(owner.symbol))
    elseif mode == :write && !is_mutable(r)
        throw(BorrowRuleError("Cannot write to immutable reference"))
    end
    return unsafe_get_value(r)
end

function unsafe_set_value!(r::OwnedMut, value)
    return setfield!(r, :value, value)
end
function set_value!(r::AllOwned, value)
    if !is_mutable(r)
        throw(BorrowRuleError("Cannot assign to immutable"))
    elseif is_moved(r)
        throw(MovedError(r.symbol))
    elseif r.mutable_borrows > 0 || r.immutable_borrows > 0
        throw(BorrowRuleError("Cannot assign to value while borrowed"))
    end
    return unsafe_set_value!(r, value)
end
function set_value!(::AllBorrowed, value)
    throw(BorrowRuleError("Cannot assign to borrowed"))
end

# Public getters and setters
function Base.getproperty(o::AllOwned, name::Symbol)
    if name == :value
        error("Use `@take` to directly access the value of an owned variable")
    end
    if name in (:moved, :immutable_borrows, :mutable_borrows, :symbol)
        return getfield(o, name)
    else
        value = request_value(o, Val(:read))
        if recursive_ismutable(value)
            # TODO: This is kind of where rust would check
            #       the Copy trait. What should we do?
            mark_moved!(o)
            return constructorof(typeof(o))(getproperty(value, name))
        else
            return constructorof(typeof(o))(getproperty(value, name))
        end
    end
end
function Base.setproperty!(o::AllOwned, name::Symbol, v)
    if name in (:moved, :immutable_borrows, :mutable_borrows)
        setfield!(o, name, v)
    else
        value = request_value(o, Val(:write))
        setproperty!(value, name, v)
    end
    return o
end
function Base.getproperty(r::AllBorrowed, name::Symbol)
    if name == :owner
        return getfield(r, :owner)
    elseif name == :lifetime
        return getfield(r, :lifetime)
    end
    value = getproperty(request_value(r, Val(:read)), name)
    return constructorof(typeof(r))(value, r.owner, r.lifetime)
end
function Base.setproperty!(r::AllBorrowed, name::Symbol, value)
    name == :owner && error("Cannot modify reference ownership")
    result = setproperty!(request_value(r, Val(:write)), name, value)
    return constructorof(typeof(r))(result, r.owner, r.lifetime)
end

# Convenience functions
function Base.propertynames(o::AllWrappers)
    return propertynames(unsafe_get_value(o))
end
function Base.show(io::IO, o::AllOwned)
    if is_moved(o)
        print(io, "[moved]")
    else
        constructor = constructorof(typeof(o))
        value = request_value(o, Val(:read))
        print(io, "$(constructor){$(typeof(value))}($(value))")
    end
end
function Base.show(io::IO, r::AllBorrowed)
    if is_moved(r)
        print(io, "[reference to moved value]")
    else
        constructor = constructorof(typeof(r))
        value = request_value(r, Val(:read))
        owner = r.owner
        print(io, "$(constructor){$(typeof(value)),$(typeof(owner))}($(value))")
    end
end

end
