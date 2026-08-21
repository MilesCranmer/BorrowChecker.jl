module BorrowChecker

include("preferences.jl")
include("auto.jl")

export @safe, @unsafe, BorrowCheckError
export disable_by_default!

# Not exported but still available
using .Auto: @auto, @safe, @unsafe, BorrowCheckError
using .PreferencesModule: disable_by_default!

end
