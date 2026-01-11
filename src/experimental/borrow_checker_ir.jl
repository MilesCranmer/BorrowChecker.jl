export @borrow_checker,
    Config, DEFAULT_CONFIG, BorrowCheckError, register_effects!, register_return_alias!

import Core.Compiler
const CC = Core.Compiler

include("defs.jl")
include("diagnostics.jl")
include("ir_primitives.jl")
include("callsite.jl")
include("summaries.jl")
include("alias.jl")
include("liveness.jl")
include("checker.jl")
include("frontend.jl")
