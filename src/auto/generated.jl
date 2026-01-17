using Core.Compiler
using Core.IR

struct BCInterpOwner end
Base.@kwdef struct BCInterp <: Compiler.AbstractInterpreter
    world::UInt = Base.get_world_counter()
    inf_params::Compiler.InferenceParams = Compiler.InferenceParams()
    opt_params::Compiler.OptimizationParams = Compiler.OptimizationParams()
    inf_cache::Vector{Compiler.InferenceResult} = Compiler.InferenceResult[]
    codegen_cache::IdDict{CodeInstance,CodeInfo} = IdDict{CodeInstance,CodeInfo}()
end
Base.Experimental.@MethodTable BCMT

struct GeneratedCfgTag{S,MSD,OPT} end

Compiler.InferenceParams(interp::BCInterp) = interp.inf_params
Compiler.OptimizationParams(interp::BCInterp) = interp.opt_params
Compiler.get_inference_world(interp::BCInterp) = interp.world
Compiler.get_inference_cache(interp::BCInterp) = interp.inf_cache
Compiler.cache_owner(::BCInterp) = BCInterpOwner()
Compiler.codegen_cache(interp::BCInterp) = interp.codegen_cache
Compiler.method_table(interp::BCInterp) = Compiler.OverlayMethodTable(interp.world, BCMT)

function _cfg_from_tag(
    ::Type{GeneratedCfgTag{S,MSD,OPT}}, tt::Type{<:Tuple}, world::UInt
) where {S,MSD,OPT}
    @nospecialize tt
    scope = S::Symbol
    max_summary_depth = MSD::Int
    optimize_until = String(OPT::Symbol)

    root_module = if scope === :module
        matches = Base._methods_by_ftype(tt, -1, world)
        if isnothing(matches) || isempty(matches)
            Main
        else
            (matches[1]::Core.MethodMatch).method.module
        end
    else
        Main
    end

    return Config(optimize_until, max_summary_depth, scope, root_module)
end

function _tt_cfg_from_sig(sig::DataType, world::UInt)
    @nospecialize sig
    # `sig` is a type like:
    #   Tuple{GeneratedCfgTag{...}, typeof(f), typeof(x), ...}
    tt = try
        Core.apply_type(Tuple, sig.parameters[2:end]...)
    catch
        sig
    end
    tt isa Type{<:Tuple} ||
        error("_generated_assert_safe expected a config-tagged Tuple type; got $sig")
    return tt, _cfg_from_tag(sig.parameters[1]::Type{<:GeneratedCfgTag}, tt, world)
end

function _generated_assert_safe_body(world::UInt, lnn, this, sig)
    sig = sig.parameters[1]

    tt, cfg = _tt_cfg_from_sig(sig, world)

    check_signature(tt; cfg, world) # Do the actual checking

    ci = _expr_to_codeinfo(
        @__MODULE__(), [Symbol("#self#"), :sig], [], :(return nothing), false
    )

    matches = Base._methods_by_ftype(tt, -1, world)
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
    body = Expr(:block, Expr(:return, Expr(:block, e)))
    scope = Expr(Symbol("scope-block"), body)
    lambda = Expr(:lambda, argnames, scope)
    ex = if isnothing(spnames) || isempty(spnames)
        lambda
    else
        Expr(Symbol("with-static-parameters"), lambda, spnames...)
    end
    ci = Base.generated_body_to_codeinfo(ex, @__MODULE__(), isva)
    @assert ci isa Core.CodeInfo "Failed to create a CodeInfo from the given expression. This might mean it contains a closure or comprehension?\n Offending expression: $e"
    return ci
end

#! format: off
function _refresh_generated_assert_safe()
    @eval function _generated_assert_safe(sig::Type{<:Tuple{<:GeneratedCfgTag,Vararg{Any}}})
        $(Expr(:meta, :generated_only))
        $(Expr(:meta, :generated, _generated_assert_safe_body))
    end

    # Don't recursively borrow check the borrow checking!
    @eval Base.Experimental.@overlay BCMT _generated_assert_safe(sig) = nothing
end
#! format: on
#
# NOTE: `check_signature` is defined in `frontend.jl`, and Julia 1.12+ is stricter
# about calling "too-new" methods from generated-function contexts. We therefore
# delay defining `_generated_assert_safe` until after `frontend.jl` is loaded.
