module BorrowCheckerJETLSExt

using BorrowChecker: BorrowChecker
using JETLS: JETLS

const BORROW_CHECK_CODE = "inference/borrow-check-error"

struct BorrowCheckerJETLSPlugin <: JETLS.AbstractJETLSPlugin end

const PLUGIN = BorrowCheckerJETLSPlugin()

function __init__()
    JETLS.register_diagnostic_code!(BORROW_CHECK_CODE)
    JETLS.register_plugin!(PLUGIN; owner=BorrowChecker)
    return nothing
end

function _borrowcheck_error(report::JETLS.JET.InferenceErrorReport)
    report isa JETLS.JET.GeneratorErrorReport || return nothing
    err = JETLS.unwrap_loaderror(report.err)
    err isa BorrowChecker.Auto.BorrowCheckError || return nothing
    return err
end

function _violation_uri_and_range(v::BorrowChecker.Auto.BorrowViolation)
    li = v.lineinfo
    li === nothing && return nothing

    file = try
        getproperty(li, :file)
    catch
        return nothing
    end
    line = try
        Int(getproperty(li, :line))
    catch
        return nothing
    end

    file === Symbol("") && return nothing
    line <= 0 && return nothing

    file_str = String(file)
    startswith(file_str, "REPL[") && return nothing

    uri = if startswith(file_str, "Untitled")
        JETLS.filename2uri(file_str)
    else
        JETLS.filepath2uri(JETLS.to_full_path(file))
    end

    line0 = max(line - 1, 0)
    pos = JETLS.LSP.Position(line0, 0)
    range = JETLS.LSP.Range(pos, pos)
    return (uri, range)
end

function JETLS.plugin_modify_jetconfigs!(
    ::BorrowCheckerJETLSPlugin, ::JETLS.ScriptAnalysisEntry, jetconfigs::Dict{Symbol,Any}
)
    jetconfigs[:analyze_from_definitions] = true
    return nothing
end
function JETLS.plugin_modify_jetconfigs!(
    ::BorrowCheckerJETLSPlugin,
    ::JETLS.ScriptInEnvAnalysisEntry,
    jetconfigs::Dict{Symbol,Any},
)
    jetconfigs[:analyze_from_definitions] = true
    return nothing
end

function JETLS.plugin_additional_report_uris(
    ::BorrowCheckerJETLSPlugin, report::JETLS.JET.InferenceErrorReport
)
    err = _borrowcheck_error(report)
    err === nothing && return JETLS.URI[]

    uris = JETLS.URI[]
    for v in err.violations
        loc = _violation_uri_and_range(v)
        loc === nothing && continue
        uri, _ = loc
        push!(uris, uri)
    end
    return uris
end

function JETLS.plugin_expand_inference_error_report!(
    ::BorrowCheckerJETLSPlugin,
    uri2diagnostics::JETLS.URI2Diagnostics,
    report::JETLS.JET.InferenceErrorReport,
    ::JETLS.JET.PostProcessor,
)::Bool
    err = _borrowcheck_error(report)
    err === nothing && return false

    for v in err.violations
        loc = _violation_uri_and_range(v)
        loc === nothing && continue
        uri, range = loc

        diag = JETLS.LSP.Diagnostic(;
            range,
            severity=JETLS.LSP.DiagnosticSeverity.Error,
            code=BORROW_CHECK_CODE,
            source="BorrowChecker",
            message=v.msg,
        )

        push!(
            get!(uri2diagnostics, uri) do
                JETLS.LSP.Diagnostic[]
            end,
            diag,
        )
    end

    return true
end

end # module BorrowCheckerJETLSExt
