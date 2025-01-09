module SemanticsModule

using ..TypesModule:
    Bound,
    BoundMut,
    Borrowed,
    BorrowedMut,
    AllBound,
    AllBorrowed,
    AllWrappers,
    AllMutable,
    AllImmutable,
    Lifetime,
    constructorof,
    is_mutable,
    mark_moved!,
    is_moved,
    unsafe_get_value
using ..ErrorsModule: MovedError, BorrowRuleError, SymbolMismatchError
using ..UtilsModule: recursive_ismutable

# Internal getters and setters

function validate_symbol(r::AllBound, expected_symbol::Symbol)
    if expected_symbol != r.symbol && r.symbol != :anonymous
        throw(SymbolMismatchError(r.symbol, expected_symbol))
    end
end

function validate_symbol(r::AllBorrowed, expected_symbol::Symbol)
    if expected_symbol != r.symbol && r.symbol != :anonymous
        throw(SymbolMismatchError(r.symbol, expected_symbol))
    end
end

# Skip validation for primitive types
validate_symbol(_, ::Symbol) = nothing

function request_value(r::AllBound, ::Val{mode}) where {mode}
    @assert mode in (:read, :write, :move)
    if is_moved(r)
        throw(MovedError(r.symbol))
    elseif is_mutable(r) && r.mutable_borrows > 0
        throw(BorrowRuleError("Cannot access original while mutably borrowed"))
    elseif !is_mutable(r) && mode == :write
        throw(BorrowRuleError("Cannot write to immutable"))
    elseif mode in (:write, :move) && r.immutable_borrows > 0
        throw(BorrowRuleError("Cannot $mode original while immutably borrowed"))
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

function unsafe_set_value!(r::BoundMut, value)
    return setfield!(r, :value, value, :sequentially_consistent)
end
function set_value!(r::AllBound, value)
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
function wrapped_getter(f::F, o::AllBound, k) where {F}
    value = request_value(o, Val(:read))
    if recursive_ismutable(value)
        # TODO: This is kind of where rust would check
        #       the Copy trait. What should we do?
        mark_moved!(o)
    end
    return constructorof(typeof(o))(f(value, k))
end
function wrapped_getter(f::F, r::AllBorrowed, k) where {F}
    value = f(request_value(r, Val(:read)), k)
    return constructorof(typeof(r))(value, r.owner, r.lifetime)
end
function wrapped_setter(f::F, o::AllWrappers, k, v) where {F}
    value = request_value(o, Val(:write))
    return f(value, k, v)
end

function Base.getproperty(o::AllBound, name::Symbol)
    if name == :value
        error("Use `@take` to directly access the value of an owned variable")
    end
    if name in (:moved, :immutable_borrows, :mutable_borrows, :symbol)
        return getfield(o, name)
    else
        return wrapped_getter(getproperty, o, name)
    end
end
function Base.getproperty(r::AllBorrowed, name::Symbol)
    if name in (:owner, :lifetime, :symbol)
        return getfield(r, name)
    else
        return wrapped_getter(getproperty, r, name)
    end
end
function Base.setproperty!(o::AllBound, name::Symbol, v)
    if name in (:moved, :immutable_borrows, :mutable_borrows)
        setfield!(o, name, v, :sequentially_consistent)
    else
        wrapped_setter(setproperty!, o, name, v)
    end
    return o
end
function Base.setproperty!(r::AllBorrowed, name::Symbol, value)
    name == :owner && error("Cannot modify reference ownership")
    result = wrapped_setter(setproperty!, r, name, value)
    # TODO: I think we should return `nothing` here instead, or
    #       some other marker.
    return constructorof(typeof(r))(result, r.owner, r.lifetime)
end

# Convenience functions
function Base.propertynames(o::AllWrappers)
    return propertynames(unsafe_get_value(o))
end
function Base.show(io::IO, o::AllBound)
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

function take(var::AllBound, var_symbol::Symbol)
    validate_symbol(var, var_symbol)
    if isbitstype(typeof(request_value(var, Val(:read))))
        # For isbits types, we just clone:
        return deepcopy(request_value(var, Val(:read)))
    else
        # For non-isbits types, we move:
        value = request_value(var, Val(:move))
        mark_moved!(var)
        return value
    end
end

function move(
    src::AllBound, src_symbol::Symbol, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    validate_symbol(src, src_symbol)
    if isbitstype(typeof(request_value(src, Val(:read))))
        # For isbits types, we just clone:
        value = deepcopy(request_value(src, Val(:read)))
    else
        # For non-isbits types, we move:
        value = request_value(src, Val(:move))
        mark_moved!(src)
    end
    return mut ? BoundMut(value, false, dest_symbol) : Bound(value, false, dest_symbol)
end

function bind(value, symbol::Symbol, ::Val{mut}) where {mut}
    return mut ? BoundMut(value, false, symbol) : Bound(value, false, symbol)
end

function set(dest::AllBound, dest_symbol::Symbol, value)
    validate_symbol(dest, dest_symbol)
    return set_value!(dest, value)
end

function set(dest::AllBorrowed, dest_symbol::Symbol, value)
    validate_symbol(dest, dest_symbol)
    if !is_mutable(dest)
        throw(BorrowRuleError("Cannot write to immutable reference"))
    end
    return set_value!(dest.owner, value)
end

function clone(
    src::AllWrappers, src_symbol::Symbol, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    validate_symbol(src, src_symbol)
    # Get the value from either a reference or owned value:
    value = deepcopy(request_value(src, Val(:read)))
    return mut ? BoundMut(value, false, dest_symbol) : Bound(value, false, dest_symbol)
end

function cleanup!(lifetime::Lifetime)
    # Clean up immutable references
    for owner in lifetime.immutable_refs
        owner.immutable_borrows -= 1
    end
    empty!(lifetime.immutable_refs)

    # Clean up mutable references
    for owner in lifetime.mutable_refs
        owner.mutable_borrows -= 1
    end
    return empty!(lifetime.mutable_refs)
end

function ref(
    lt::Lifetime, ref_or_owner::AllWrappers, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    is_owner = ref_or_owner isa AllBound
    owner = is_owner ? ref_or_owner : ref_or_owner.owner

    if !is_owner
        @assert(
            ref_or_owner.lifetime === lt,
            "Lifetime mismatch! Nesting lifetimes is not allowed."
        )
    end

    if mut
        return BorrowedMut(ref_or_owner, lt, dest_symbol)
    else
        if is_owner
            return Borrowed(owner, lt, dest_symbol)
        else
            return Borrowed(request_value(ref_or_owner, Val(:read)), owner, lt, dest_symbol)
        end
    end
end

function bind_for(iter, symbol::Symbol)
    return Iterators.map(x -> Bound(x, false, symbol), iter)
end

end
