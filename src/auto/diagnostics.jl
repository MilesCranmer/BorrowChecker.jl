struct BorrowViolation
    idx::Int
    msg::String
    lineinfo::Union{Nothing,Any}
    stmt::Any
    kind::Symbol
    problem_var::Symbol
    other_var::Symbol
    other_lineinfo::Union{Nothing,Any}
    problem_argpos::Int
end

struct BorrowCheckError <: Exception
    tt::Any
    violations::Vector{BorrowViolation}
end

function BorrowViolation(idx::Int, msg::String, lineinfo, stmt)
    return BorrowViolation(
        idx, msg, lineinfo, stmt, :generic, :anonymous, :anonymous, nothing, 0
    )
end

using JuliaSyntaxHighlighting: highlight
using StyledStrings: Face, face!
import Base.JuliaSyntax: GreenNode, children, kind, parseall, span, @K_str

struct CachedFileLines
    mtime::Float64
    size::Int64
    lines::Vector{String}
end

const SRCFILE_CACHE = Lockable(Dict{String,CachedFileLines}())

@inline function _lineinfo_file_line(li)
    file = try
        String(getproperty(li, :file))
    catch
        nothing
    end
    line = try
        Int(getproperty(li, :line))
    catch
        nothing
    end
    return file, line
end

const REPL_FILE_RE = r"^REPL\[(\d+)\]$"
const REPL_LINEMARK_RE = r"^\s*#=\s*REPL\[\d+\]:\d+\s*=#\s*$"

function _repl_hist_entry_content(entry)
    entry isa AbstractString && return String(entry)
    if hasproperty(entry, :content)
        c = try
            getproperty(entry, :content)
        catch
            nothing
        end
        c isa AbstractString && return String(c)
    end
    return nothing
end

function _try_repl_history_provider()
    isdefined(Base, :active_repl) || return nothing
    repl = Base.active_repl
    repl === nothing && return nothing

    hp = nothing
    try
        iface = getproperty(repl, :interface)
        modes = getproperty(iface, :modes)
        if modes isa AbstractVector
            for mode in modes
                hasproperty(mode, :hist) || continue
                cand = getproperty(mode, :hist)
                cand === nothing && continue
                hasproperty(cand, :history) || continue
                hp = cand
                break
            end
        end
    catch
        hp = nothing
    end
    return hp
end

function _try_repl_source_lines(file::AbstractString, line::Int)
    line <= 0 && return nothing

    m = match(REPL_FILE_RE, file)
    m === nothing && return nothing

    hp = _try_repl_history_provider()
    hp === nothing && return nothing

    cap = m.captures[1]
    cap === nothing && return nothing
    n = parse(Int, cap)
    n <= 0 && return nothing

    hist = try
        getproperty(hp, :history)
    catch
        return nothing
    end
    hist isa AbstractVector || return nothing
    isempty(hist) && return nothing

    function usable_lines(src)
        src_str = _repl_hist_entry_content(src)
        src_str === nothing && return nothing
        src_str = replace(src_str, '\r' => "")
        lines = split(src_str, '\n'; keepempty=true)
        (1 <= line <= length(lines)) || return nothing
        l = strip(lines[line])
        isempty(l) && return nothing
        occursin(REPL_LINEMARK_RE, l) && return nothing
        return lines
    end

    # First try the direct "REPL[n]" indexing heuristics.
    if hasproperty(hp, :start_idx)
        start_idx = try
            getproperty(hp, :start_idx)
        catch
            nothing
        end
        if start_idx isa Integer
            for idx in (Int(start_idx) + n, Int(start_idx) + n - 1)
                (1 <= idx <= length(hist)) || continue
                lines = usable_lines(hist[idx])
                lines !== nothing && return lines
            end
        end
    end

    for idx in (n, n - 1)
        (1 <= idx <= length(hist)) || continue
        lines = usable_lines(hist[idx])
        lines !== nothing && return lines
    end

    # Fallback: scan recent history for a multi-line entry that has a usable target line.
    # This is robust against REPL/history behavior changes across Julia versions.
    for idx in length(hist):-1:1
        src = _repl_hist_entry_content(hist[idx])
        src === nothing && continue
        occursin('\n', src) || continue
        lines = usable_lines(src)
        lines !== nothing && return lines
    end

    return nothing
end

function _try_source_lines(file::AbstractString, line::Int)
    if isfile(file)
        return _read_file_lines(String(file))
    end
    return _try_repl_source_lines(file, line)
end

function _lineinfo_chain(li::Core.LineInfoNode)
    chain = Core.LineInfoNode[]
    cur = li
    while cur isa Core.LineInfoNode
        push!(chain, cur)
        cur = try
            getproperty(cur, :inlined_at)
        catch
            nothing
        end
    end
    return chain
end

function _read_file_lines(file::String)
    st = try
        stat(file)
    catch
        return String[]
    end

    mtime = Float64(st.mtime)
    size = Int64(st.size)

    @lock SRCFILE_CACHE begin
        cache = SRCFILE_CACHE[]
        entry = get(cache, file, nothing)
        if entry !== nothing && entry.mtime == mtime && entry.size == size
            return entry.lines
        end

        lines = try
            readlines(file)
        catch
            String[]
        end
        cache[file] = CachedFileLines(mtime, size, lines)
        return lines
    end
end

function _recover_callee_from_tt(tt)
    try
        tt_u = Base.unwrap_unionall(tt)
        tt_u isa DataType || return (nothing, nothing)
        ps = tt_u.parameters
        isempty(ps) && return (nothing, nothing)
        fT = ps[1]
        Base.issingletontype(fT) || return (nothing, nothing)
        f = getfield(fT, :instance)
        argT = Tuple{ps[2:end]...}
        return (f, argT)
    catch
        return (nothing, nothing)
    end
end

function _io_color_enabled(io::IO)
    return try
        get(io, :color, false)::Bool
    catch
        false
    end
end

struct UnderlineInfo
    sym::Symbol
    argpos::Int
end

const _EMPTY_GREEN_CHILDREN = GreenNode[]

@inline function _children_or_empty(n::GreenNode)
    c = children(n)
    return c === nothing ? _EMPTY_GREEN_CHILDREN : c
end

@inline function _leaf_eq_token(n::GreenNode)
    return kind(n) == K"=" && span(n) == 1 && isempty(_children_or_empty(n))
end

function _collect_identifier_ranges!(
    out::Vector{UnitRange{Int}},
    line::AbstractString,
    node::GreenNode,
    off::Int,
    needle::String,
)
    if kind(node) == K"Identifier"
        if (off + span(node)) <= ncodeunits(line) &&
            line[(off + 1):(off + span(node))] == needle
            push!(out, (off + 1):(off + span(node)))
        end
        return nothing
    end

    if kind(node) == K"="
        # Skip LHS identifiers; only underline identifiers in the RHS.
        o = off
        seen_eq = false
        for ch in _children_or_empty(node)
            if !seen_eq
                _leaf_eq_token(ch) && (seen_eq = true)
                o += span(ch)
                continue
            end
            kind(ch) == K"Whitespace" && (o += span(ch); continue)
            _collect_identifier_ranges!(out, line, ch, o, needle)
            o += span(ch)
        end
        return nothing
    end

    o = off
    for ch in _children_or_empty(node)
        _collect_identifier_ranges!(out, line, ch, o, needle)
        o += span(ch)
    end
    return nothing
end

function _parameters_value_nodes(params::GreenNode, off::Int)
    # Return expression nodes representing keyword argument *values* in evaluation order.
    vals = Tuple{GreenNode,Int}[]
    o = off
    for ch in _children_or_empty(params)
        k = kind(ch)
        if k == K";" || k == K"," || k == K"Whitespace"
            o += span(ch)
            continue
        end

        if k == K"="
            # RHS = first non-whitespace node after the leaf '=' token.
            co = o
            seen_eq = false
            for cch in _children_or_empty(ch)
                if !seen_eq
                    _leaf_eq_token(cch) && (seen_eq = true)
                    co += span(cch)
                    continue
                end
                kind(cch) == K"Whitespace" && (co += span(cch); continue)
                push!(vals, (cch, co))
                break
            end
            o += span(ch)
            continue
        end

        # Implicit kwargs like `; x` and splats like `; kwargs...`.
        push!(vals, (ch, o))
        o += span(ch)
    end
    return vals
end

function _tuple_value_nodes(node::GreenNode, off::Int)
    # Return expression nodes representing tuple element *values* in evaluation order.
    vals = Tuple{GreenNode,Int}[]

    # NamedTuple/kwargs form: tuple has a `parameters` child containing `=` nodes.
    o = off
    params = nothing
    params_off = 0
    for ch in _children_or_empty(node)
        if kind(ch) == K"parameters"
            params = ch
            params_off = o
            break
        end
        o += span(ch)
    end

    if params !== nothing
        return _parameters_value_nodes(params, params_off)
    end

    # Regular tuple: each non-punctuation/non-whitespace child is an element expression.
    o = off
    for ch in _children_or_empty(node)
        k = kind(ch)
        if k == K"(" || k == K")" || k == K"," || k == K"Whitespace"
            o += span(ch)
            continue
        end
        push!(vals, (ch, o))
        o += span(ch)
    end
    return vals
end

function _call_value_nodes(node::GreenNode, off::Int)
    # Return expression nodes representing call argument *values* in evaluation order (excluding callee).
    vals = Tuple{GreenNode,Int}[]
    o = off
    first = true
    for ch in _children_or_empty(node)
        if first
            # Callee expression.
            o += span(ch)
            first = false
            continue
        end

        k = kind(ch)
        if k == K"(" || k == K")" || k == K"," || k == K"Whitespace"
            o += span(ch)
            continue
        end

        if k == K"parameters"
            append!(vals, _parameters_value_nodes(ch, o))
            o += span(ch)
            continue
        end

        push!(vals, (ch, o))
        o += span(ch)
    end
    return vals
end

function _underline_ranges_for_argpos(
    line::AbstractString, ast::GreenNode, sym::Symbol, argpos::Int
)
    elem_idx = argpos - 1
    elem_idx >= 1 || return UnitRange{Int}[]
    needle = String(sym)

    function find_ranges(node::GreenNode, off::Int)
        k = kind(node)
        if k == K"call" || k == K"tuple"
            vals = if (k == K"call")
                _call_value_nodes(node, off)
            else
                _tuple_value_nodes(node, off)
            end
            if length(vals) >= elem_idx
                (elem_node, elem_off) = vals[elem_idx]
                ranges = UnitRange{Int}[]
                _collect_identifier_ranges!(ranges, line, elem_node, elem_off, needle)
                isempty(ranges) || return ranges
            end
        end
        o = off
        for ch in _children_or_empty(node)
            found = find_ranges(ch, o)
            found !== nothing && return found
            o += span(ch)
        end
        return nothing
    end

    found = find_ranges(ast, 0)
    return found === nothing ? UnitRange{Int}[] : found
end

function _underline_ranges(line::AbstractString, ast::GreenNode, underline::UnderlineInfo)
    underline.sym == :anonymous && return UnitRange{Int}[]
    needle = String(underline.sym)

    if underline.argpos >= 2
        ranges = _underline_ranges_for_argpos(line, ast, underline.sym, underline.argpos)
        isempty(ranges) || return ranges
        # Fallback: underline RHS occurrences.
    end

    ranges = UnitRange{Int}[]
    _collect_identifier_ranges!(ranges, line, ast, 0, needle)
    return ranges
end

function _print_highlighted_line(
    io::IO, line::AbstractString, underline::Union{Nothing,UnderlineInfo}
)
    if !_io_color_enabled(io)
        print(io, line)
        return nothing
    end

    ast = parseall(GreenNode, String(line); ignore_errors=true)
    s = highlight(String(line), ast)

    if underline !== nothing
        for r in _underline_ranges(line, ast, underline)
            face!(s[r], Face(; underline=true))
        end
    end

    Base.AnnotatedDisplay.ansi_write(print, io, s)
    return nothing
end

function _print_source_context(
    io::IO, tt, li; context::Int=0, underline::Union{Nothing,UnderlineInfo}=nothing
)
    file, line = if li isa Core.LineInfoNode || li isa LineNumberNode
        _lineinfo_file_line(li)
    else
        return nothing
    end
    (file === nothing || line === nothing) && return nothing

    if li isa Core.LineInfoNode
        chain = _lineinfo_chain(li)
        for (k, c) in enumerate(chain)
            f, l = _lineinfo_file_line(c)
            (f === nothing || l === nothing) && continue
            if k == 1
                println(io, "      at ", f, ":", l)
            else
                println(io, "      inlined at ", f, ":", l)
            end
        end
    else
        println(io, "      at ", file, ":", line)
    end

    lines = _try_source_lines(file, line)
    if lines !== nothing && 1 <= line <= length(lines)
        lo = max(1, line - context)
        hi = min(length(lines), line + context)
        for ln in lo:hi
            prefix = (ln == line) ? "      > " : "        "
            print(io, prefix, rpad(string(ln), 5), " ")
            _print_highlighted_line(io, lines[ln], (ln == line) ? underline : nothing)
            println(io)
        end
        return nothing
    end

    f, argT = _recover_callee_from_tt(tt)
    (f === nothing || argT === nothing) && return nothing

    cis = try
        Base.code_lowered(f, argT; debuginfo=:source)
    catch
        try
            Base.code_lowered(f, argT)
        catch
            Any[]
        end
    end
    isempty(cis) && return nothing

    filesym = Symbol(file)
    for ci in cis
        ci isa Core.CodeInfo || continue
        buf = Any[]

        collecting = false
        for st in ci.code
            if st isa LineNumberNode
                if collecting
                    break
                end
                collecting = (st.file == filesym && st.line == line)
                continue
            end
            collecting || continue
            push!(buf, st)
        end

        if isempty(buf)
            def = try
                which(f, argT)
            catch
                nothing
            end

            if def !== nothing
                last_file = Symbol("")
                last_line = 0
                first_idx = 0
                for i in 1:length(ci.code)
                    scopes = Base.Compiler.IRShow.buildLineInfoNode(ci.debuginfo, def, i)
                    if !isempty(scopes)
                        li = scopes[1]
                        last_file = li.file
                        last_line = Int(li.line)
                    end
                    if last_file == filesym && last_line == line
                        first_idx = i
                        break
                    end
                end

                if first_idx != 0
                    for j in first_idx:length(ci.code)
                        scopes = Base.Compiler.IRShow.buildLineInfoNode(
                            ci.debuginfo, def, j
                        )
                        if !isempty(scopes)
                            li = scopes[1]
                            last_file = li.file
                            last_line = Int(li.line)
                        end
                        (last_file == filesym && last_line == line) || break
                        push!(buf, ci.code[j])
                    end
                end
            end
        end

        if !isempty(buf)
            println(io, "      lowered:")
            for ex in buf
                s = try
                    sprint(show, ex)
                catch
                    ""
                end
                isempty(s) || println(io, "        ", s)
            end
            break
        end

        println(io, "      lowered:")
        n = min(6, length(ci.code))
        for i in 1:n
            s = try
                sprint(show, ci.code[i])
            catch
                ""
            end
            isempty(s) || println(io, "        ", s)
        end
        break
    end

    return nothing
end

function Base.showerror(io::IO, e::BorrowCheckError)
    print(io, "BorrowCheckError for specialization ", e.tt)

    try
        (f, argT) = _recover_callee_from_tt(e.tt)
        m = which(f, argT)
        print(io, "\n\n  method: ", m)
    catch
    end

    for (i, v) in enumerate(e.violations)
        println(io)
        println(io)
        print(io, "  [", i, "] stmt#", v.idx, ": ", v.msg)
        if v.lineinfo !== nothing
            try
                _print_source_context(
                    io,
                    e.tt,
                    v.lineinfo;
                    context=2,
                    underline=UnderlineInfo(v.problem_var, v.problem_argpos),
                )
            catch
                println(io, "      ", v.lineinfo)
            end
        end
        if v.other_lineinfo !== nothing && v.other_var != :anonymous
            try
                println(io)
                println(io)
                p = (v.problem_var == :anonymous) ? "value" : "`$(v.problem_var)`"
                o = if (v.other_var == :anonymous)
                    "another live binding"
                else
                    "`$(v.other_var)`"
                end
                println(
                    io,
                    "      note: ",
                    p,
                    " became problematic due to ",
                    o,
                    " introduced here",
                )
                _print_source_context(
                    io,
                    e.tt,
                    v.other_lineinfo;
                    context=2,
                    underline=UnderlineInfo(v.other_var, 0),
                )
            catch
            end
        end
        println(io)
        print(io, "      stmt: ", v.stmt)
    end
end
