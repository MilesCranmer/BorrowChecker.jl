module Auto

using ..PreferencesModule: is_borrow_checker_enabled
using DispatchDoctor: @unstable

export @auto, @safe, @unsafe

@static if isdefined(Base, :code_ircode_by_type) && v"1.12.0-" <= VERSION < v"1.15.0-"
    @unstable include("auto/auto_ir.jl")
else
    # COV_EXCL_START
    """
    Automatic compiler-IR borrow checker.

    This feature requires `Base.code_ircode_by_type`.
    """
    "Unavailable `@auto` stub for unsupported Julia versions."
    macro auto(args...)
        ex = args[end]
        is_borrow_checker_enabled(__module__) || return esc(ex)
        Base.depwarn(
            "`BorrowChecker.@auto` is deprecated; use `BorrowChecker.@safe` instead.", :auto
        )
        @warn(
            "BorrowChecker.Auto.@safe is not supported on this version of Julia.",
            maxlog = 1,
        )
        return esc(ex)
    end

    "Unavailable `@safe` stub for unsupported Julia versions."
    macro safe(args...)
        ex = args[end]
        is_borrow_checker_enabled(__module__) || return esc(ex)
        @warn(
            "BorrowChecker.Auto.@safe is not supported on this version of Julia.",
            maxlog = 1,
        )
        return esc(ex)
    end

    "Unavailable `@unsafe` stub for unsupported Julia versions."
    macro unsafe(ex)
        # When the auto-IR checker is unavailable, `@unsafe` is a no-op.
        return esc(ex)
    end
    # COV_EXCL_STOP
end

end
