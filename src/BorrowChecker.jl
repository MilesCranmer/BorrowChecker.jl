module BorrowChecker

using MacroTools
using MacroTools: rmlines

include("utils.jl")
include("errors.jl")
include("types.jl")
include("semantics.jl")
include("macros.jl")
include("overloads.jl")

using .ErrorsModule: BorrowError, MovedError, BorrowRuleError, SymbolMismatchError
using .TypesModule: Owned, OwnedMut, Borrowed, BorrowedMut
using .MacrosModule: @bind, @move, @ref, @take, @set, @lifetime

export @bind, @move, @ref, @take, @set, @lifetime
export Owned, OwnedMut, Borrowed, BorrowedMut
export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError

# Not exported but still available
using .UtilsModule: recursive_ismutable
using .TypesModule: is_moved

end
