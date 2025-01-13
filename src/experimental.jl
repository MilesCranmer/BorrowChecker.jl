"""
This module provides experimental features that are not yet stable enough
for the main API.
"""
module Experimental

using ..CassetteOverlay
using ..TypesModule: AllBound, Bound, BoundMut, Borrowed, BorrowedMut, is_moved, get_symbol
using ..StaticTraitModule: is_static
using ..SemanticsModule: request_value, mark_moved!, unsafe_get_value
using ..MacrosModule: @take!
using ..PreferencesModule: is_borrow_checker_enabled
using ..ErrorsModule: MovedError, BorrowRuleError

# First define the regular functions
function maybe_take!(x)
    return x
end

function maybe_take!(arg::AllBound)
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

# Create the method table for our overlay
@MethodTable BorrowCheckerOverlay

# # Handle regular function calls
# @overlay BorrowCheckerOverlay function (pass::Any)(f::Function, args...)
#     @nospecialize f args
#     @nonoverlay println("DEBUG: Function overlay called with f = ", f, " and args = ", args)
#     # Transform each argument via maybe_take!
#     unwrapped_args = @nonoverlay map(maybe_take!, args)
#     @nonoverlay println("DEBUG: Unwrapped args = ", unwrapped_args, @nonoverlay typeof(unwrapped_args))
#     # Call the raw function using nonoverlay to prevent recursion
#     return @nonoverlay f(unwrapped_args...)
# end

# Catch-all overlay for any function call that didn't match the more specific methods
@overlay BorrowCheckerOverlay function (pass::Any)(f::Any, args...)
    @nospecialize f args
    @nonoverlay println("DEBUG: Catch-all overlay called with f = ", f, " and args = ", args)
    # Transform each argument via maybe_take!
    unwrapped_args = @nonoverlay map(maybe_take!, args)
    @nonoverlay println("DEBUG: Unwrapped args = ", unwrapped_args, @nonoverlay typeof(unwrapped_args))
    # Call the raw function using nonoverlay to prevent recursion
    return @nonoverlay f(unwrapped_args...)
end

# Create the pass - this will automatically generate the main pass method
# that handles do-blocks via first(fargs)(Base.tail(fargs)...)
const borrow_checker_pass = @overlaypass BorrowCheckerOverlay

"""
    @managed f()

Run code with automatic ownership transfer enabled. Any `Bound` or `BoundMut` arguments
passed to functions within the block will automatically have their ownership transferred
using the equivalent of `@take!`.

!!! warning
    This is an experimental feature and may change or be removed in future versions.
"""
macro managed(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return esc(
        quote
            $(borrow_checker_pass)() do
                begin
                    $expr
                end
            end
        end,
    )
end

end
