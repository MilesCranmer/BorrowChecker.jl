export Config,
    DEFAULT_CONFIG, BorrowCheckError, register_effects!, register_foreigncall_effects!

import Core.Compiler
const CC = Core.Compiler

include("utils.jl")
include("defs.jl")
include("diagnostics.jl")
include("ir_primitives.jl")
include("callsite.jl")
include("summaries.jl")
include("alias.jl")
include("checker.jl")
include("generated.jl")
include("frontend.jl")
