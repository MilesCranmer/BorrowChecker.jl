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
include("disambiguations.jl")

#! format: off
using .ErrorsModule: BorrowError, MovedError, BorrowRuleError, SymbolMismatchError, ExpiredError, AliasedReturnError
using .TypesModule: Owned, OwnedMut, Borrowed, BorrowedMut, LazyAccessor, OrBorrowed, OrBorrowedMut
using .MacrosModule: @own, @move, @ref, @take, @take!, @lifetime, @clone, @bc, @mut

export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError, ExpiredError
export Owned, OwnedMut, Borrowed, BorrowedMut, LazyAccessor, OrBorrowed, OrBorrowedMut
export @own, @move, @ref, @take, @take!, @lifetime, @clone, @bc, @mut

# Not exported but still available
using .PreferencesModule: disable_by_default!
using .StaticTraitModule: is_static
using .TypesModule: AsMutable, Lifetime, LazyAccessorOf, is_moved, get_owner, get_symbol, get_immutable_borrows, get_mutable_borrows
#! format: on

end
