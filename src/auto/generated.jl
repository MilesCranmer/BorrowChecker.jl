using Core.Compiler
using Core.IR

struct BCInterpOwner; end
struct BCInterp <: Compiler.AbstractInterpreter
    world::UInt
    inf_params::Compiler.InferenceParams
    opt_params::Compiler.OptimizationParams
    inf_cache::Vector{Compiler.InferenceResult}
    codegen_cache::IdDict{CodeInstance,CodeInfo}
    function BCInterp(;
        world::UInt = Base.get_world_counter(),
        inf_params::Compiler.InferenceParams = Compiler.InferenceParams(),
        opt_params::Compiler.OptimizationParams = Compiler.OptimizationParams(),
        inf_cache::Vector{Compiler.InferenceResult} = Compiler.InferenceResult[])
        new(world, inf_params, opt_params, inf_cache, IdDict{CodeInstance,CodeInfo}())
    end
end
Base.Experimental.@MethodTable BCMT 

Compiler.InferenceParams(interp::BCInterp) = interp.inf_params
Compiler.OptimizationParams(interp::BCInterp) = interp.opt_params
Compiler.get_inference_world(interp::BCInterp) = interp.world
Compiler.get_inference_cache(interp::BCInterp) = interp.inf_cache
Compiler.cache_owner(::BCInterp) = BCInterpOwner()
Compiler.codegen_cache(interp::BCInterp) = interp.codegen_cache
Compiler.method_table(interp::BCInterp) = Compiler.OverlayMethodTable(interp.world, BCMT)

function _generated_assert_safe_body(world::UInt, lnn, this, sig)
    sig = sig.parameters[1]
    cfg = DEFAULT_CONFIG

    check_signature(sig; cfg, world) # Do the actual checking

    ci = _expr_to_codeinfo(@__MODULE__(), [Symbol("#self#"), :sig], [], :(return nothing), false)
    
    matches = Base._methods_by_ftype(sig, -1, world)
    if !isnothing(matches)
        ci.edges = Any[]
        for match in matches
            mi = Base.specialize_method(match) 
            push!(ci.edges, mi)
        end
    end
    return ci
end

function _expr_to_codeinfo(m::Module, argnames, spnames, e::Expr, isva)
    lam = Expr(:lambda, argnames,
               Expr(Symbol("scope-block"),
                    Expr(:block,
                         Expr(:return,
                              Expr(:block,
                                   e,
                                   )))))
    ex = if spnames === nothing || isempty(spnames)
        lam
    else
        Expr(Symbol("with-static-parameters"), lam, spnames...)
    end
    ci = Base.generated_body_to_codeinfo(ex, @__MODULE__(), isva)
    @assert ci isa Core.CodeInfo "Failed to create a CodeInfo from the given expression. This might mean it contains a closure or comprehension?\n Offending expression: $e"
    ci
end

function _refresh_generated_assert_safe()
    @eval function _generated_assert_safe(sig)
        $(Expr(:meta, :generated_only))
        $(Expr(:meta, :generated, _generated_assert_safe_body))
    end
end
_refresh_generated_assert_safe()

# Don't recursively borrow check the borrow checking!
Base.Experimental.@overlay BCMT _generated_assert_safe(sig) = nothing

