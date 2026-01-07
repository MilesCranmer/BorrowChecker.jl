module Experimental

using ..PreferencesModule: is_borrow_checker_enabled

@static if VERSION >= v"1.14.0-"
    include("experimental/borrow_checker_ir.jl")
else
    """
    Experimental compiler-IR borrow checker.

    This feature requires Julia `>= 1.14.0-` (e.g. a nightly build).
    """
    macro borrow_checker(ex)
        is_borrow_checker_enabled(__module__) || return esc(ex)
        return error("BorrowChecker.Experimental.@borrow_checker requires Julia >= 1.14.0-")
    end
end

end
