module SemanticsModule

using ..TypesModule:
    Owned,
    OwnedMut,
    Borrowed,
    BorrowedMut,
    AllOwned,
    AllBorrowed,
    AllEager,
    AllWrappers,
    AllMutable,
    AllImmutable,
    Lifetime,
    LazyAccessor,
    LazyAccessorOf,
    AsMutable,
    constructorof,
    is_mutable,
    mark_moved!,
    mark_expired!,
    is_moved,
    is_expired,
    unsafe_get_value,
    unsafe_access,
    has_lifetime,
    get_lifetime,
    get_owner,
    get_symbol,
    get_immutable_borrows,
    get_mutable_borrows,
    decrement_immutable_borrows!,
    decrement_mutable_borrows!
using ..StaticTraitModule: is_static
using ..ErrorsModule: MovedError, BorrowRuleError, SymbolMismatchError, ExpiredError

# Internal getters and setters

function validate_symbol(r::AllOwned, expected_symbol::Symbol)
    if expected_symbol != get_symbol(r) &&
        get_symbol(r) != :anonymous &&
        expected_symbol != :anonymous
        throw(SymbolMismatchError(get_symbol(r), expected_symbol))
    end
end

function validate_symbol(::AllBorrowed, _::Symbol)
    # We don't check borrowed symbols, since
    # they are typically passed to functions
    return nothing
end

# Skip validation for primitive types
validate_symbol(_, ::Symbol) = nothing

function validate_mode(r::AllOwned, ::Val{mode}) where {mode}
    @assert mode in (:read, :write, :move)
    if is_moved(r)
        throw(MovedError(get_symbol(r)))
    elseif is_mutable(r) && get_mutable_borrows(r) > 0
        var_str = get_symbol(r) == :anonymous ? "original" : "`$(get_symbol(r))`"
        throw(BorrowRuleError("Cannot access $(var_str) while mutably borrowed"))
    elseif !is_mutable(r) && mode == :write
        var_str = get_symbol(r) == :anonymous ? "immutable" : "immutable `$(get_symbol(r))`"
        throw(BorrowRuleError("Cannot write to $(var_str)"))
    elseif mode in (:write, :move) && get_immutable_borrows(r) > 0
        var_str = get_symbol(r) == :anonymous ? "original" : "`$(get_symbol(r))`"
        throw(BorrowRuleError("Cannot $(mode) $(var_str) while immutably borrowed"))
    end
    return nothing
end
function validate_mode(r::AllBorrowed, ::Val{mode}) where {mode}
    @assert mode in (:read, :write)
    owner = get_owner(r)
    if is_moved(owner)
        throw(MovedError(get_symbol(owner)))
    elseif is_expired(r)
        throw(ExpiredError(get_symbol(r)))
    elseif mode == :write && !is_mutable(r)
        var_str = if get_symbol(r) == :anonymous
            "immutable reference"
        else
            "immutable reference `$(get_symbol(r))`"
        end
        throw(BorrowRuleError("Cannot write to $(var_str)"))
    end
    return nothing
end
function request_value(r::AllOwned, ::Val{mode}) where {mode}
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

@inline function Base.getproperty(o::AllOwned, name::Symbol)
    return LazyAccessor(o, Val(name))
end
@inline function Base.getproperty(r::AllBorrowed, name::Symbol)
    return LazyAccessor(r, Val(name))
end
@inline function Base.getproperty(
    r::LazyAccessor{T,P,property}, name::Symbol
) where {T,P,property}
    return LazyAccessor(r, Val(name))
end
@inline function Base.setproperty!(o::AllOwned, name::Symbol, value)
    setproperty!(request_value(o, Val(:write)), name, value)
    return nothing
end
@inline function Base.setproperty!(r::AllBorrowed, name::Symbol, value)
    setproperty!(request_value(r, Val(:write)), name, value)
    return nothing
end
@inline function Base.setproperty!(r::LazyAccessor, name::Symbol, value)
    target = getfield(r, :target)
    setproperty!(request_value(target, Val(:write)), name, value)
    return nothing
end

# Convenience functions
function Base.propertynames(o::AllEager)
    return propertynames(unsafe_get_value(o))
end
function Base.show(io::IO, o::AllOwned)
    if is_moved(o)
        print(io, "[moved]")
    else
        constructor = constructorof(typeof(o))
        value = request_value(o, Val(:read))
        symbol = get_symbol(o)
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
        symbol = get_symbol(r)
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

maybe_deepcopy(x) = is_static(x) ? x : deepcopy(x)

function take!(src::Union{AllOwned{T},LazyAccessor{T}}, src_symbol) where {T}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = if is_static(T)
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

function take(src::Union{AllOwned,AllBorrowed,LazyAccessor}, src_symbol)
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = request_value(src, Val(:read))
    if is_static(value)
        return value
    else
        return deepcopy(value)
    end
end

# Fallbacks
take!(x, _) = x
take(x, _) = deepcopy(x)

function move(
    src::Union{AllOwned{T},LazyAccessor{T}}, src_symbol, dest_symbol, ::Val{mut}
) where {T,mut}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    value = if is_static(T)
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
    return mut ? OwnedMut(value, false, dest_symbol) : Owned(value, false, dest_symbol)
end

function own(src, _, dest_symbol::Symbol, ::Val{mut}) where {mut}
    return mut ? OwnedMut(src, false, dest_symbol) : Owned(src, false, dest_symbol)
end
function own(src::AllOwned, src_expr, dest_symbol::Symbol, ::Val{mut}) where {mut}
    src_symbol = src_expr isa Symbol ? src_expr : :anonymous
    return move(src, src_symbol, dest_symbol, Val(mut))
end
function own(src::AllBorrowed, src_expr, dest_symbol::Symbol, ::Val{mut}) where {mut}
    src_symbol = src_expr isa Symbol ? src_expr : :anonymous
    var_str =
        src_symbol == :anonymous ? "a borrowed object" : "borrowed object `$(src_symbol)`"
    throw(BorrowRuleError("Cannot own $(var_str)."))
end

function clone(src::AllWrappers, src_symbol, dest_symbol::Symbol, ::Val{mut}) where {mut}
    src_symbol isa Symbol && validate_symbol(src, src_symbol)
    # Get the value from either a borrowed or owned value:
    value = let v = request_value(src, Val(:read))
        is_static(v) ? v : deepcopy(v)
    end

    return mut ? OwnedMut(value, false, dest_symbol) : Owned(value, false, dest_symbol)
end

function cleanup!(lifetime::Lifetime)
    is_expired(lifetime) && error("Cannot cleanup expired lifetime")
    mark_expired!(lifetime)

    # Clean up immutable references
    Base.@lock lifetime.immutables_lock begin
        for owner in lifetime.immutable_refs
            decrement_immutable_borrows!(owner)
        end
        empty!(lifetime.immutable_refs)
    end

    # Clean up mutable references
    Base.@lock lifetime.mutables_lock begin
        for owner in lifetime.mutable_refs
            decrement_mutable_borrows!(owner)
        end
        empty!(lifetime.mutable_refs)
    end

    return nothing
end

function ref(
    lt::Lifetime, ref_or_owner::AllWrappers, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    is_owner = ref_or_owner isa AllOwned
    owner = get_owner(ref_or_owner)

    if has_lifetime(ref_or_owner)
        @assert(
            get_lifetime(ref_or_owner) === lt,
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
function ref(lt::Lifetime, value, owner::AllOwned, dest_symbol::Symbol, ::Val{false})
    return Borrowed(value, owner, lt, dest_symbol)
end
function ref(lt::Lifetime, value, owner::AllOwned, dest_symbol::Symbol, ::Val{true})
    return BorrowedMut(value, owner, lt, dest_symbol)
end
function ref(
    lt::Lifetime, value, r::Union{AllBorrowed,LazyAccessor}, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    return ref(lt, value, get_owner(r), dest_symbol, Val(mut))
end

function own_for(iter, symbol, ::Val{mut}) where {mut}
    symbols = symbol isa Symbol ? Iterators.repeated(symbol) : symbol
    return Iterators.map(((x, s),) -> own(x, :anonymous, s, Val(mut)), zip(iter, symbols))
end
function own_for(iter::AllOwned, symbol, ::Val{mut}) where {mut}
    return own_for(take(iter, :anonymous), symbol, Val(mut))
end

function ref_for(
    lt::Lifetime, ref_or_owner::Union{B,LazyAccessorOf{B}}, symbol, ::Val{mut}
) where {mut,B<:Union{AllOwned,Borrowed}}
    owner = get_owner(ref_or_owner)
    value = request_value(ref_or_owner, Val(:read))
    symbols = symbol isa Symbol ? Iterators.repeated(symbol) : symbol
    return Iterators.map(
        RefMapper(lt, ref_or_owner, owner, Val(mut)), enumerate(zip(value, symbols))
    )
    # TODO: Make this more robust
end

struct RefMapper{mut,R,O<:AllOwned}
    lifetime::Lifetime
    ref::R
    owner::O
    v_mut::Val{mut}
end
function (m::RefMapper{mut})((i, (x, s))) where {mut}
    # Since this is a single array, we are
    # technically only referencing it once.
    if i > 1
        if mut
            pop_owner!(m.lifetime.mutable_refs, m.owner, m.lifetime.mutables_lock)
            decrement_mutable_borrows!(m.owner)
        else
            pop_owner!(m.lifetime.immutable_refs, m.owner, m.lifetime.immutables_lock)
            decrement_immutable_borrows!(m.owner)
        end
        # TODO: Verify this in tests, for extra (im)mutable before/after loop
    end
    return ref(m.lifetime, x, m.ref, s, Val(mut))
end
function pop_owner!(refs::Vector, owner::AllOwned, lock)
    Base.@lock lock begin
        i = findlast(Base.Fix1(===, owner), refs)
        if isnothing(i)
            error(
                "We could not find the owner in the mutable refs. Please submit a bug report.",
            )
        else
            popat!(refs, i)
        end
    end
end
# TODO: Much simpler if we just don't add the owner in the first place.
#       There should be a better overall design here.

#! format: off
function maybe_ref(
    lt::Lifetime, wrapper::AsMutable, var_symbol::Symbol, ::Val{false}=Val(false)
)
    return maybe_ref(lt, wrapper.value, var_symbol, Val(true))
end
function maybe_ref(
    lt::Lifetime, val::Union{O,LazyAccessorOf{O}}, var_symbol::Symbol, ::Val{mut}=Val(false)
) where {T,O<:AllOwned{T},mut}
    is_static(T) && return request_value(val, Val(:read))
    return ref(lt, val, var_symbol, Val(mut))
end
function maybe_ref(
    ::Lifetime, val::Union{AllBorrowed,LazyAccessorOf{AllBorrowed}}, ::Symbol, ::Val{mut}=Val(false)
) where {mut}
    return val
end
function maybe_ref(
    ::Lifetime, val, ::Symbol, ::Val{mut}=Val(false)
) where {mut}
    return val
end
#! format: on

end
