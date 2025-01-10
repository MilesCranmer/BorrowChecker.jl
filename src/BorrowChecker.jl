module BorrowChecker

using MacroTools
using MacroTools: rmlines

include("utils.jl")
include("errors.jl")
include("types.jl")
include("preferences.jl")
include("semantics.jl")
include("macros.jl")
include("overloads.jl")
include("managed.jl")

using .ErrorsModule: BorrowError, MovedError, BorrowRuleError, SymbolMismatchError
using .TypesModule: Bound, BoundMut, Borrowed, BorrowedMut
using .MacrosModule: @bind, @move, @ref, @take, @set, @lifetime, @clone
using .ManagedModule: @managed
using .PreferencesModule: disable_borrow_checker!

export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError
export Bound, BoundMut, Borrowed, BorrowedMut
export @bind, @move, @ref, @take, @set, @lifetime, @clone

# Not exported but still available
using .TypesModule: is_moved

end
