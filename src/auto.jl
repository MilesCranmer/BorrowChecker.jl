module Auto

using ..PreferencesModule: is_borrow_checker_enabled
using DispatchDoctor: @unstable

@static if isdefined(Base, :code_ircode_by_type) && v"1.12.0-" <= VERSION < v"1.15.0-"
    @unstable include("auto/auto_ir.jl")
else
    """
    Automatic compiler-IR borrow checker.

    This feature requires `Base.code_ircode_by_type`.
    """
    macro auto(ex)
        is_borrow_checker_enabled(__module__) || return esc(ex)
        @warn(
            "BorrowChecker.Auto.@auto is not supported on this version of Julia.",
            maxlog = 1,
        )
        return esc(ex)
    end
end

end
