module Experimental

using ..PreferencesModule: is_borrow_checker_enabled
using DispatchDoctor: @unstable

@static if isdefined(Base, :code_ircode_by_type)
    @unstable include("experimental/borrow_checker_ir.jl")
else
    """
    Experimental compiler-IR borrow checker.

    This feature requires `Base.code_ircode_by_type`.
    """
    macro borrow_checker(ex)
        is_borrow_checker_enabled(__module__) || return esc(ex)
        return error("BorrowChecker.Experimental.@borrow_checker requires Base.code_ircode_by_type")
    end
end

end
