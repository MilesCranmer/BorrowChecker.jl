module BorrowChecker

include("preferences.jl")
include("auto.jl")

export @safe, @unsafe, disable_by_default!

# Not exported but still available
using .Auto: @auto, @safe, @unsafe
using .PreferencesModule: disable_by_default!

# `BorrowCheckError` only exists where the automatic checker is supported
# (Julia >= 1.12 with `Base.code_ircode_by_type`); older versions get stubs.
if isdefined(Auto, :BorrowCheckError)
    export BorrowCheckError
    using .Auto: BorrowCheckError
end

end
