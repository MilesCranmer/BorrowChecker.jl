export @borrow_checker,
    Config,
    DEFAULT_CONFIG,
    BorrowCheckError,
    register_effects!,
    register_fresh_return!,
    register_return_alias!

import Core.Compiler
const CC = Core.Compiler

include("defs.jl")
include("analysis.jl")
include("frontend.jl")
