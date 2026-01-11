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

const _srcfile_cache = Lockable(Dict{String,Vector{String}}())

@inline function _lineinfo_file_line(li::Core.LineInfoNode)
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

@inline function _lineinfo_file_line(li::LineNumberNode)
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
    lines = String[]
    @lock _srcfile_cache begin
        lines = get!(_srcfile_cache[], file) do
            try
                readlines(file)
            catch
                String[]
            end
        end
    end
    return lines
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

    if isfile(file)
        lines = _read_file_lines(file)
        if 1 <= line <= length(lines)
            lo = max(1, line - context)
            hi = min(length(lines), line + context)
            for ln in lo:hi
                prefix = (ln == line) ? "      > " : "        "
                println(io, prefix, rpad(string(ln), 5), " ", lines[ln])
            end
            return nothing
        end
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
            lt = try
                getproperty(ci, :linetable)
            catch
                nothing
            end
            locs = try
                getproperty(ci, :codelocs)
            catch
                nothing
            end
            if lt !== nothing && locs !== nothing
                first_idx = 0
                for i in 1:min(length(ci.code), length(locs))
                    loc = locs[i]
                    (loc isa Integer) || continue
                    lii = Int(loc)
                    (lii <= 0 || lii > length(lt)) && continue
                    li = lt[lii]
                    li isa Core.LineInfoNode || continue
                    (
                        String(getproperty(li, :file)) == file &&
                        Int(getproperty(li, :line)) == line
                    ) || continue
                    first_idx = i
                    break
                end
                if first_idx != 0
                    li0 = lt[Int(locs[first_idx])]
                    for j in first_idx:min(length(ci.code), length(locs))
                        loc = locs[j]
                        (loc isa Integer) || break
                        lii = Int(loc)
                        (lii <= 0 || lii > length(lt)) && break
                        lij = lt[lii]
                        lij == li0 || break
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
        (file, line) = Base.functionloc(m)
        print(io, "\n\n  method: ", m, " at ", file, ":", line)
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
