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

@inline function _is_generated_cfg_tag_type(@nospecialize(x))::Bool
    dt = Base.unwrap_unionall(x)
    return dt isa DataType && dt.name === Base.unwrap_unionall(GeneratedCfgTag).name
end

function _cfg_from_tag(tag, tt::Type{<:Tuple}, world::UInt)
    tag = Base.unwrap_unionall(tag)
    @assert tag isa DataType

    scope = tag.parameters[1]
    max_summary_depth = tag.parameters[2]
    optimize_until = tag.parameters[3]

    cfg0 = DEFAULT_CONFIG
    scope = something(scope, cfg0.scope)
    max_summary_depth = something(max_summary_depth, cfg0.max_summary_depth)
    optimize_until = something(optimize_until, cfg0.optimize_until)

    root_module = if scope === :module
        matches = Base._methods_by_ftype(tt, -1, world)
        if isnothing(matches) || isempty(matches)
            cfg0.root_module
        else
            (matches[1]::Core.MethodMatch).method.module
        end
    else
        cfg0.root_module
    end

    return Config(optimize_until, max_summary_depth, scope, root_module)
end

function _tt_cfg_from_sig(sig::DataType, world::UInt)
    # `sig` is a type like:
    #   Tuple{GeneratedCfgTag{...}, typeof(f), typeof(x), ...}
    tt = try
        Core.apply_type(Tuple, sig.parameters[2:end]...)
    catch
        sig
    end
    tt isa Type{<:Tuple} || return sig, DEFAULT_CONFIG
    return tt, _cfg_from_tag(sig.parameters[1], tt, world)
end

function _generated_assert_safe_body(world::UInt, lnn, this, sig)
    sig = sig.parameters[1]

    tt, cfg = if sig isa DataType && !isempty(sig.parameters) && _is_generated_cfg_tag_type(sig.parameters[1])
        _tt_cfg_from_sig(sig, world)
    else
        sig, DEFAULT_CONFIG
    end

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
    @eval function _generated_assert_safe(sig)
        $(Expr(:meta, :generated_only))
        $(Expr(:meta, :generated, _generated_assert_safe_body))
    end
end
#! format: on
_refresh_generated_assert_safe()

# Don't recursively borrow check the borrow checking!
Base.Experimental.@overlay BCMT _generated_assert_safe(sig) = nothing
