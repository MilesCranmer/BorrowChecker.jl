module BorrowChecker

include("preferences.jl")

using .PreferencesModule: disable_by_default!, is_borrow_checker_enabled
using DispatchDoctor: @unstable

# The borrow checker: `@safe` instruments methods with a compiler-IR borrow
# check at runtime. This is the entire library.
export @safe, @unsafe, disable_by_default!

@static if isdefined(Base, :code_ircode_by_type) && v"1.12.0-" <= VERSION < v"1.14.0-"
    @unstable include("safe/auto_ir.jl")
    # `BorrowCheckError` and friends are defined by safe/auto_ir.jl.
    export BorrowCheckError
else
    # COV_EXCL_START
    """
        BorrowChecker.@auto

    Deprecated alias for [`BorrowChecker.@safe`](@ref).
    """
    "Unavailable `@auto` stub for unsupported Julia versions."
    macro auto(args...)
        ex = args[end]
        is_borrow_checker_enabled(__module__) || return esc(ex)
        Base.depwarn(
            "`BorrowChecker.@auto` is deprecated; use `BorrowChecker.@safe` instead.", :auto
        )
        @warn(
            "BorrowChecker.@safe is not supported on this version of Julia.",
            maxlog = 1,
        )
        return esc(ex)
    end

    "Unavailable `@safe` stub for unsupported Julia versions."
    macro safe(args...)
        ex = args[end]
        is_borrow_checker_enabled(__module__) || return esc(ex)
        @warn(
            "BorrowChecker.@safe is not supported on this version of Julia.",
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
