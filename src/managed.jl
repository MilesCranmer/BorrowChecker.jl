"""
This module provides Cassette-based automatic ownership transfer functionality.
It allows owned values (`Bound` and `BoundMut`) to be automatically taken when
passed to functions, without requiring explicit `@take!` calls.
"""
module ManagedModule

using Cassette: Cassette
using ..TypesModule: AllBound, Bound, BoundMut, Borrowed, BorrowedMut, is_moved
using ..SemanticsModule: request_value, mark_moved!, unsafe_get_value
using ..MacrosModule: @take!
using ..PreferencesModule: is_borrow_checker_enabled

# Create the Cassette context for ownership transfer
Cassette.@context ManagedCtx

function maybe_take!(x)
    return x
end
function maybe_take!(arg::AllBound)
    is_moved(arg) && throw(MovedError(arg.symbol))
    value = unsafe_get_value(arg)
    if isbits(value)
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

#! format: off
const SKIP_METHODS = (
    Base.getindex, Base.setindex!, Base.getproperty,
    Base.setproperty!, Base.getfield, Base.setfield!
)
#! format: on
function skip_method(f)
    # Don't modify our own methods!
    own_function = parentmodule(parentmodule(f)) == parentmodule(@__MODULE__)
    return own_function || f in SKIP_METHODS
end

# Overdub all method calls, other than the ones defined in our library,
# to automatically take ownership of Bound/BoundMut arguments
function Cassette.overdub(ctx::ManagedCtx, f, args...)
    if skip_method(f)
        return Cassette.fallback(ctx, f, args...)
    else
        return Cassette.recurse(ctx, f, map(maybe_take!, args)...)
    end
end

const CleanManagedCtx = Cassette.disablehooks(ManagedCtx())

"""
    @managed f()

Run code with automatic ownership transfer enabled. Any `Bound` or `BoundMut` arguments
passed to functions within the block will automatically have their ownership transferred
using the equivalent of `@take!`.
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
