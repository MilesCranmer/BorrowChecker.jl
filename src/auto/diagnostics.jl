struct BorrowViolation
    idx::Int
    msg::String
    lineinfo::Union{Nothing,Any}
    stmt::Any
end

struct BorrowCheckError <: Exception
    tt::Any
    violations::Vector{BorrowViolation}
end

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

function _print_source_context(io::IO, tt, li; context::Int=0)
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
            println(io, prefix, rpad(string(ln), 5), " ", lines[ln])
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
                _print_source_context(io, e.tt, v.lineinfo; context=2)
            catch
                println(io, "      ", v.lineinfo)
            end
        end
        println(io)
        print(io, "      stmt: ", v.stmt)
    end
end
