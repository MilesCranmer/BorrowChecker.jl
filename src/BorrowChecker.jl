module BorrowChecker

using MacroTools
using MacroTools: rmlines

include("utils.jl")
include("errors.jl")
include("types.jl")
include("semantics.jl")
include("macros.jl")
include("overloads.jl")

using .ErrorsModule: BorrowError, MovedError, BorrowRuleError
using .TypesModule: Owned, OwnedMut, Borrowed, BorrowedMut
using .MacrosModule: @own, @move, @ref, @take, @set, @lifetime
using .UtilsModule: recursive_ismutable

export @own, @move, @ref, @take, @set, @lifetime
export Owned, OwnedMut, Borrowed, BorrowedMut
export MovedError, BorrowError, BorrowRuleError

end
