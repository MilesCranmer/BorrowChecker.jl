module SemanticsModule

using ..TypesModule:
    Bound,
    BoundMut,
    Borrowed,
    BorrowedMut,
    AllBound,
    AllBorrowed,
    AllEager,
    AllWrappers,
    AllMutable,
    AllImmutable,
    Lifetime,
    LazyAccessor,
    constructorof,
    is_mutable,
    mark_moved!,
    is_moved,
    is_expired,
    unsafe_get_value,
    unsafe_access,
    has_lifetime,
    get_owner
using ..ErrorsModule: MovedError, BorrowRuleError, SymbolMismatchError, ExpiredError

# Internal getters and setters

function validate_symbol(r::AllBound, expected_symbol::Symbol)
    if expected_symbol != r.symbol &&
        r.symbol != :anonymous &&
        expected_symbol != :anonymous
        throw(SymbolMismatchError(r.symbol, expected_symbol))
    end
end

function validate_symbol(r::AllBorrowed, expected_symbol::Symbol)
    if expected_symbol != r.symbol &&
        r.symbol != :anonymous &&
        expected_symbol != :anonymous
        throw(SymbolMismatchError(r.symbol, expected_symbol))
    end
end

# Skip validation for primitive types
validate_symbol(_, ::Symbol) = nothing

function validate_mode(r::AllBound, ::Val{mode}) where {mode}
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
    return nothing
end
function validate_mode(r::AllBorrowed, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    owner = get_owner(r)
    if is_moved(owner)
        throw(MovedError(owner.symbol))
    elseif is_expired(r)
        throw(ExpiredError(r.symbol))
    elseif mode == :write && !is_mutable(r)
        throw(BorrowRuleError("Cannot write to immutable reference"))
    end
    return nothing
end
function request_value(r::AllBound, ::Val{mode}) where {mode}
    validate_mode(r, Val(mode))
    return unsafe_get_value(r)
end
function request_value(r::AllBorrowed, ::Val{mode}) where {mode}
    validate_mode(r, Val(mode))
    return unsafe_get_value(r)
end
function request_value(r::LazyAccessor, ::Val{mode}) where {mode}
    target = getfield(r, :target)
    validate_mode(target, Val(mode))
    return unsafe_access(r)
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

@inline function Base.getproperty(o::AllBound, name::Symbol)
    if name == :value
        error("Use `@take` to directly access the value of a bound variable")
    end
    if name in (:moved, :immutable_borrows, :mutable_borrows, :symbol)
        # TODO: This is not safe, because the user's type might
        #       have properties of this name!
        return getfield(o, name)
    else
        return LazyAccessor(o, Val(name))
    end
end
@inline function Base.getproperty(r::AllBorrowed, name::Symbol)
    if name in (:owner, :lifetime, :symbol)
        return getfield(r, name)
    else
        return LazyAccessor(r, Val(name))
    end
end
@inline function Base.getproperty(
    r::LazyAccessor{T,P,property}, name::Symbol
) where {T,P,property}
    return LazyAccessor(r, Val(name))
end
@inline function Base.setproperty!(o::AllBound, name::Symbol, v)
    if name in (:moved, :immutable_borrows, :mutable_borrows)
        setfield!(o, name, v, :sequentially_consistent)
    else
        setproperty!(request_value(o, Val(:write)), k, v)
    end
    return o
end
@inline function Base.setproperty!(r::AllBorrowed, name::Symbol, value)
    name == :owner && error("Cannot modify reference ownership")
    setproperty!(request_value(r, Val(:write)), name, value)
    # TODO: I think we should return `nothing` here instead, or
    #       some other marker.
    return value
end
@inline function Base.setproperty!(r::LazyAccessor, name::Symbol, value)
    target = getfield(r, :target)
    setproperty!(request_value(target, Val(:write)), name, value)
    return value
end

# Convenience functions
function Base.propertynames(o::AllEager)
    return propertynames(unsafe_get_value(o))
end
function Base.show(io::IO, o::AllBound)
    if is_moved(o)
        print(io, "[moved]")
    else
        constructor = constructorof(typeof(o))
        value = request_value(o, Val(:read))
        symbol = o.symbol
        print(io, "$(constructor){$(typeof(value))}($(value), :$(symbol))")
    end
end
function Base.show(io::IO, r::AllBorrowed)
    if is_moved(r)
        # TODO: I don't think we can ever get here?
        print(io, "[reference to moved value]")  # COV_EXCL_LINE
    else
        constructor = constructorof(typeof(r))
        value = request_value(r, Val(:read))
        owner = get_owner(r)
        symbol = r.symbol
        print(io, "$(constructor){$(typeof(value)),$(typeof(owner))}($(value), :$(symbol))")
    end
end
function Base.show(io::IO, r::LazyAccessor)
    owner = get_owner(r)
    if is_moved(owner)
        print(io, "[moved]")
    else
        value = request_value(r, Val(:read))
        print(io, value)
        # TODO: What's the right way to print this?
    end
end

function take!(src::Union{AllBound{T},LazyAccessor{T}}, src_symbol) where {T}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = if isbitstype(T)
        # For isbits types, we do not need to worry
        # about the original getting modified, and thus
        # we do NOT need to deepcopy it.
        request_value(src, Val(:read))
    else
        # For non-isbits types, we move:
        v = request_value(src, Val(:move))
        mark_moved!(src)
        v
    end
    return value
end

function take(src::Union{AllBound,LazyAccessor}, src_symbol)
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = request_value(src, Val(:read))
    if isbits(value)
        return value
    else
        return deepcopy(value)
    end
end

# Fallbacks
take!(x, _) = x
take(x, _) = deepcopy(x)

function move(
    src::Union{AllBound{T},LazyAccessor{T}}, src_symbol, dest_symbol, ::Val{mut}
) where {T,mut}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = if isbitstype(T)
        # For isbits types, we do not need to worry
        # about the original getting modified, and thus
        # we do NOT need to deepcopy it.
        request_value(src, Val(:read))
    else
        # For non-isbits types, we move:
        v = request_value(src, Val(:move))
        mark_moved!(src)
        v
    end
    return mut ? BoundMut(value, false, dest_symbol) : Bound(value, false, dest_symbol)
end

function bind(src, _, dest_symbol::Symbol, ::Val{mut}) where {mut}
    return mut ? BoundMut(src, false, dest_symbol) : Bound(src, false, dest_symbol)
end
function bind(src::AllBound, src_expr, dest_symbol::Symbol, ::Val{mut}) where {mut}
    src_symbol = src_expr isa Symbol ? src_expr : :anonymous
    return move(src, src_symbol, dest_symbol, Val(mut))
end
function bind(::AllBorrowed, _, ::Symbol, ::Val{mut}) where {mut}
    throw(BorrowRuleError("Cannot bind a borrowed object."))
end

function set(dest::AllBound, dest_symbol, value)
    dest_symbol isa Symbol && validate_symbol(dest, dest_symbol)
    return set_value!(dest, value)
end

function set(dest::AllBorrowed, dest_symbol::Symbol, value)
    validate_symbol(dest, dest_symbol)
    if !is_mutable(dest)
        throw(BorrowRuleError("Cannot write to immutable reference"))
    end
    return set_value!(get_owner(dest), value)
end

function clone(src::AllWrappers, src_symbol, dest_symbol::Symbol, ::Val{mut}) where {mut}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    # Get the value from either a borrowed or bound value:
    value = let v = request_value(src, Val(:read))
        isbits(v) ? v : deepcopy(v)
    end

    return mut ? BoundMut(value, false, dest_symbol) : Bound(value, false, dest_symbol)
end

function cleanup!(lifetime::Lifetime)
    lifetime.expired[] = true

    # Clean up immutable references
    for owner in lifetime.immutable_refs
        owner.immutable_borrows -= 1
    end
    empty!(lifetime.immutable_refs)

    # Clean up mutable references
    for owner in lifetime.mutable_refs
        owner.mutable_borrows -= 1
    end
    empty!(lifetime.mutable_refs)

    return nothing
end

function ref(
    lt::Lifetime, ref_or_owner::AllWrappers, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    is_owner = ref_or_owner isa AllBound
    owner = get_owner(ref_or_owner)

    if has_lifetime(ref_or_owner)
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

# These methods are used for references to a field _in_ an object
function ref(lt::Lifetime, value, owner::AllBound, dest_symbol::Symbol, ::Val{false})
    return Borrowed(value, owner, lt, dest_symbol)
end
function ref(lt::Lifetime, value, owner::AllBound, dest_symbol::Symbol, ::Val{true})
    return BorrowedMut(value, owner, lt, dest_symbol)
end
function ref(
    lt::Lifetime, value, r::AllBorrowed, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    return ref(lt, value, get_owner(r), dest_symbol, Val(mut))
end

function bind_for(iter, symbol, ::Val{mut}) where {mut}
    symbols = symbol isa Symbol ? Iterators.repeated(symbol) : symbol
    return Iterators.map(((x, s),) -> bind(x, :anonymous, s, Val(mut)), zip(iter, symbols))
end
function bind_for(iter::AllBound, symbol, ::Val{mut}) where {mut}
    return bind_for(take(iter, :anonymous), symbol, Val(mut))
end

function ref_for(
    lt::Lifetime, ref_or_owner::Union{AllBound,Borrowed}, symbol, ::Val{mut}
) where {mut}
    owner = get_owner(ref_or_owner)
    value = request_value(ref_or_owner, Val(:read))
    symbols = symbol isa Symbol ? Iterators.repeated(symbol) : symbol
    return Iterators.map(
        ((i, (x, s)),) -> let
            if i > 1 && owner.mutable_borrows == 1
                # Since this is a single array, we are
                # technically only referencing it once.
                pop!(lt.mutable_refs)
                owner.mutable_borrows = 0
                # TODO: This is very slow and not safe
            end
            ref(lt, x, ref_or_owner, s, Val(mut))
        end,
        enumerate(zip(value, symbols)),
    )
    # TODO: Make this more robust
end

end
