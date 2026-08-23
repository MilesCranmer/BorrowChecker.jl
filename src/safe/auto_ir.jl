export Config, BorrowCheckError, register_effects!, register_foreigncall_effects!

import Core.Compiler
const CC = Core.Compiler

include("utils.jl")
include("defs.jl")
include("diagnostics.jl")
include("ir_primitives.jl")
include("callsite.jl")
include("generated.jl")
include("summaries.jl")
include("refine_types.jl")
include("debug.jl")
include("alias.jl")
include("checker.jl")
include("frontend.jl")

_refresh_generated_assert_safe()
