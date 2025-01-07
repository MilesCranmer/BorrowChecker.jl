"""
This module provides Cassette-based automatic ownership transfer functionality.
It allows owned values (`Bound` and `BoundMut`) to be automatically taken when
passed to functions, without requiring explicit `@take` calls.
"""
module ManagedModule

using Cassette: Cassette
using ..TypesModule: AllBound
using ..SemanticsModule: request_value, mark_moved!, unsafe_get_value
using ..MacrosModule: @take

# Create the Cassette context for ownership transfer
Cassette.@context ManagedCtx

function maybe_take!(x)
    return x
end
function maybe_take!(arg::AllBound)
    value = unsafe_get_value(arg)
    mark_moved!(arg)
    return value
end

# Overdub all method calls to automatically take ownership of Bound/BoundMut arguments
function Cassette.overdub(ctx::ManagedCtx, f, args...)
    return Cassette.recurse(ctx, f, map(maybe_take!, args)...)
end

"""
    managed(f)

Run code with automatic ownership transfer enabled. Any `Bound` or `BoundMut` arguments
passed to functions within the block will automatically have their ownership transferred
using the equivalent of `@take`.
"""
function managed(f)
    ctx = Cassette.disablehooks(ManagedCtx())
    return Cassette.@overdub(ctx, f())
end

end
