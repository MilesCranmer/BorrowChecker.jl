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

export @bind, @move, @ref, @take, @set, @lifetime, @clone
export Bound, BoundMut, Borrowed, BorrowedMut
export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError
export @managed

# Not exported but still available
using .UtilsModule: recursive_ismutable
using .TypesModule: is_moved

end
