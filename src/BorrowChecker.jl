module BorrowChecker

using MacroTools
using MacroTools: rmlines

include("utils.jl")
include("static_trait.jl")
include("errors.jl")
include("types.jl")
include("preferences.jl")
include("semantics.jl")
include("macros.jl")
include("overloads.jl")
include("experimental.jl")

#! format: off
using .ErrorsModule: BorrowError, MovedError, BorrowRuleError, SymbolMismatchError, ExpiredError
using .TypesModule: Bound, BoundMut, Borrowed, BorrowedMut, LazyAccessor
using .MacrosModule: @bind, @move, @ref, @take, @take!, @set, @lifetime, @clone
using .PreferencesModule: disable_borrow_checker!

export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError, ExpiredError
export Bound, BoundMut, Borrowed, BorrowedMut, LazyAccessor
export @bind, @move, @ref, @take, @take!, @set, @lifetime, @clone

# Not exported but still available
using .StaticTraitModule: is_static
using .TypesModule: Lifetime, LazyAccessorOf, OrBorrowed, OrBorrowedMut, is_moved, get_owner, get_symbol, get_immutable_borrows, get_mutable_borrows
#! format: on

end
