"""
    BorrowChecker.Experimental

Module containing experimental features that may change or be removed in future versions.
Currently provides the `@managed` macro for automatic ownership transfer.
"""
module Experimental

using Cassette: Cassette
using ..TypesModule: AllOwned, Owned, OwnedMut, Borrowed, BorrowedMut, LazyAccessorOf
using ..TypesModule: is_moved, get_symbol, get_owner, unsafe_access
using ..StaticTraitModule: is_static
using ..SemanticsModule: request_value, mark_moved!, unsafe_get_value
using ..MacrosModule: @take!
using ..PreferencesModule: is_borrow_checker_enabled

# Create the Cassette context for ownership transfer
Cassette.@context ManagedCtx

function maybe_take!(x)
    return x
end
function maybe_take!(arg::AllOwned)
    is_moved(arg) && throw(MovedError(get_symbol(arg)))
    value = unsafe_get_value(arg)
    if is_static(value)
        # This is Julia-level immutable, so
        # we don't need to worry about the original
        # getting modified, and thus we do NOT need
        # to deepcopy it.
        return value
    else
        mark_moved!(arg)
        return value
    end
end
function maybe_take!(arg::LazyAccessorOf{AllOwned})
    is_moved(arg) && throw(MovedError(get_symbol(arg)))
    value = unsafe_access(arg)
    if is_static(value)
        return value
    else
        mark_moved!(arg)
        return value
    end
end

#! format: off
const SKIP_METHODS = (
    Base.getindex, Base.setindex!,
    Base.getproperty, Base.setproperty!,
    Base.getfield, Base.setfield!,
)
#! format: on
function skip_method(f::Union{Function,Type})
    # Don't modify our own methods!
    own_function = parentmodule(parentmodule(f)) == parentmodule(@__MODULE__)
    return own_function || f in SKIP_METHODS
end
skip_method(_) = false  # COV_EXCL_LINE

# Overdub all method calls, other than the ones defined in our library,
# to automatically take ownership of Owned/OwnedMut arguments
function Cassette.overdub(ctx::ManagedCtx, f, args...)
    if f == Core.setfield! &&
        length(args) == 3 &&
        args[1] isa Core.Box &&
        args[2] == :contents &&
        args[3] isa Union{AllOwned,LazyAccessorOf{AllOwned}}
        #
        symbol = get_symbol(args[3])
        error("You are not allowed to capture owned variable `$(symbol)` inside a closure.")
    end
    if skip_method(f)
        return Cassette.fallback(ctx, f, args...)
    elseif f == Core.kwcall
        (kws, actual_f, actual_args...) = args
        mapped_kws = NamedTuple{keys(kws)}(map(maybe_take!, values(kws)))
        mapped_args = map(maybe_take!, actual_args)
        return Cassette.recurse(ctx, f, mapped_kws, actual_f, mapped_args...)
    else
        mapped_args = map(maybe_take!, args)
        return Cassette.recurse(ctx, f, mapped_args...)
    end
end

const CleanManagedCtx = Cassette.disablehooks(ManagedCtx())

"""
    @managed f()

Run code with automatic ownership transfer enabled. Any `Owned` or `OwnedMut` arguments
passed to functions within the block will automatically have their ownership transferred
using the equivalent of `@take!`.

!!! warning
    This is an experimental feature and may change or be removed in future versions.
"""
macro managed(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return esc(
        quote
            $(Cassette).@overdub($(CleanManagedCtx), $(expr))
        end,
    )
end

end
