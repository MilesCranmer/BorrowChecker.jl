module BorrowChecker

using MacroTools
using MacroTools: rmlines

export @own, @move, @ref, @take, @set, @lifetime
export Owned, OwnedMut, Borrowed, BorrowedMut
export MovedError, BorrowError, BorrowRuleError

include("utils.jl")
include("types.jl")
include("errors.jl")
include("base_operations.jl")
include("macros.jl")
include("overloads.jl")

end
