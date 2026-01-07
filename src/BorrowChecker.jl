module BorrowChecker

using MacroTools
using MacroTools: rmlines
using DispatchDoctor: @stable

@stable default_mode = "disable" begin
    include("utils.jl")
    include("static_trait.jl")
    include("errors.jl")
    include("types.jl")
    include("preferences.jl")
    include("semantics.jl")
    include("mutex.jl")
    include("macros.jl")
    include("overloads.jl")
    include("type_overloads.jl")
    include("disambiguations.jl")
    include("experimental.jl")
end

#! format: off
using .ErrorsModule: BorrowError, MovedError, BorrowRuleError, SymbolMismatchError, ExpiredError, AliasedReturnError
using .TypesModule: Owned, OwnedMut, Borrowed, BorrowedMut, LazyAccessor, OrBorrowed, OrBorrowedMut
using .MacrosModule: @own, @move, @ref, @ref_into, @take, @take!, @lifetime, @clone, @bc, @mut, @cc, @&
using .MutexModule: Mutex

export MovedError, BorrowError, BorrowRuleError, SymbolMismatchError, ExpiredError
export Owned, OwnedMut, Borrowed, BorrowedMut, LazyAccessor, OrBorrowed, OrBorrowedMut
export @own, @move, @ref, @ref_into, @take, @take!, @lifetime, @clone, @bc, @mut, @cc, @&
export Mutex

# Not exported but still available
using .PreferencesModule: disable_by_default!
using .StaticTraitModule: is_static
using .TypesModule: AsMutable, Lifetime, LazyAccessorOf, is_moved, get_owner, get_symbol, get_immutable_borrows, get_mutable_borrows
using .MacrosModule: @spawn
using .MutexModule: AbstractMutex, MutexGuard, LockNotHeldError, NoOwningMutexError, MutexGuardValueAccessError
#! format: on

end
