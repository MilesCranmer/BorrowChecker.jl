@testitem "Auto @auto printing" tags = [:experimental] begin
    using TestItems
    using BorrowChecker

    # This test targets error printing helpers in the experimental borrow checker.
    using BorrowChecker.Auto: BorrowCheckError, BorrowViolation

    @testset "file source line" begin
        (path, io) = mktemp()
        close(io)
        write(path, "line1\nSENTINEL_FILE_LINE\nline3\n")

        li = LineNumberNode(2, Symbol(path))
        v = BorrowViolation(1, "msg", li, :(dummy_stmt))
        e = BorrowCheckError(Any, [v])

        s = sprint(showerror, e)
        @test occursin("at $path:2", s)
        @test occursin("SENTINEL_FILE_LINE", s)
    end

    @testset "lowered fallback (non-file source)" begin
        mod = Module(:_BCPrintUserMod)
        code = "foo!(x) = x\nfunction bar(x)\n    foo!(x)\n    return x\nend\n"
        Base.include_string(mod, code, "REPL[6]")

        bar = getfield(mod, :bar)
        tt = Tuple{typeof(bar),Int}

        li = LineNumberNode(3, Symbol("REPL[6]"))
        v = BorrowViolation(1, "msg", li, :(dummy_stmt))
        e = BorrowCheckError(tt, [v])

        s = sprint(showerror, e)
        @test occursin("at REPL[6]:3", s)
        @test occursin("lowered:", s)
        @test occursin("foo!", s)
    end

    @testset "BorrowCheckError includes REPL context (real checker)" begin
        mod = Module(:_BCPrintRealMod)
        Core.eval(mod, :(using BorrowChecker.Auto: @auto))
        Base.include_string(
            mod,
            """
            @auto function foo()
                x = [1, 2, 3]
                y = x
                push!(x, 9)
                return y
            end
            """,
            "REPL[999]",
        )

        err = try
            getfield(mod, :foo)()
            nothing
        catch e
            e
        end

        @test err isa BorrowCheckError
        s = sprint(showerror, err)
        @test occursin("REPL[999]", s)
        @test occursin("lowered:", s)
        @test occursin("push!", s)
    end

    @testset "BorrowCheckError prints file-backed source context (real checker)" begin
        (path, io) = mktemp()
        close(io)

        write(
            path,
            """
            module _BCFilePrintMod
            using BorrowChecker.Auto: @auto

            f(; x, y) = (push!(x, 1); push!(y, 1); x .+ y)

            @auto function foo()
                x = [1, 2, 3]
                y = x
                return sum(f(; x=x, y=y))
            end
            end
            """,
        )

        mod = Module(:_BCFilePrintHost)
        Base.include(mod, path)
        inner = getfield(mod, :_BCFilePrintMod)
        foo = getfield(inner, :foo)

        err = try
            foo()
            nothing
        catch e
            e
        end

        @test err isa BorrowCheckError
        s = sprint(showerror, err)
        @test occursin("at $path:", s)
        @test occursin("return sum(f(; x=x, y=y))", s)
        @test occursin(r"(?m)^\s*>\s*9\s+return sum\(f\(; x=x, y=y\)\)", s)
    end

    @testset "BorrowCheckError prints REPL source (real REPL)" begin
        using REPL
        import REPL.LineEdit
        using Base.Terminals

        function _strip_ansi(s::AbstractString)
            # Strip ANSI CSI sequences (good enough for our assertions).
            return replace(String(s), r"\e\[[0-9;?]*[ -/]*[@-~]" => "")
        end

        old_repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing

        input = Pipe()
        output = Pipe()
        err = Pipe()
        Base.link_pipe!(input; reader_supports_async=true, writer_supports_async=true)
        Base.link_pipe!(output; reader_supports_async=true, writer_supports_async=true)
        Base.link_pipe!(err; reader_supports_async=true, writer_supports_async=true)

        term = REPL.Terminals.TTYTerminal("dumb", input.out, output.in, err.in)
        repl = REPL.LineEditREPL(term, false)
        repl.options = REPL.Options(; confirm_exit=false)
        repl.history_file = false
        Base.active_repl = repl

        repltask = @async REPL.run_repl(repl)

        write(input.in, "using BorrowChecker.Auto: @auto\r")
        write(input.in, "f(; x, y) = (push!(x, 1); push!(y, 1); x .+ y)\r")
        write(
            input.in,
            "@auto function foo()\n    x = [1,2,3]\n    y = x\n    return sum(f(; x=x, y=y))\nend\r",
        )
        write(input.in, "foo()\r")
        close(input.in)

        Base.wait(repltask)
        close(output.in)
        close(err.in)

        out = _strip_ansi(read(output.out, String))
        errout = read(err.out, String)
        isempty(errout) || @test false

        @test occursin("BorrowCheckError for specialization", out)
        @test occursin("at REPL[3]:4", out)
        @test occursin("return sum(f(; x=x, y=y))", out)
        @test occursin(r"(?m)^\s*>\s*4\s+return sum\(f\(; x=x, y=y", out)

        if isdefined(Base, :active_repl)
            try
                Base.active_repl = old_repl
            catch
            end
        end
    end

    @testset "REPL history source fallback (mock active_repl)" begin
        # This test does not require an interactive REPL. We mock `Base.active_repl`
        # so `_try_repl_source` can pull text for `REPL[n]`.

        struct _BCHistMock
            history::Vector{String}
            start_idx::Int
        end
        struct _BCModeMock
            hist::_BCHistMock
        end
        struct _BCInterfaceMock
            modes::Vector{_BCModeMock}
        end
        struct _BCReplMock
            interface::_BCInterfaceMock
        end

        old_repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing

        # Try to set `Base.active_repl`. If this ever becomes non-assignable on some
        # Julia version, just skip this test.
        set_ok = true
        try
            src = "line1\nSENTINEL_REPL_LINE\nline3\n"
            # In real REPL sessions `start_idx` is the number of entries loaded from
            # the history file, and `REPL[1]` corresponds to the first entry *after*
            # that baseline: history[start_idx + 1].
            hist = ["OLD_ENTRY_1", "OLD_ENTRY_2", src]
            mock = _BCReplMock(_BCInterfaceMock([_BCModeMock(_BCHistMock(hist, 2))]))
            Base.active_repl = mock
        catch
            set_ok = false
        end

        if set_ok
            li = LineNumberNode(2, Symbol("REPL[1]"))
            v = BorrowViolation(1, "msg", li, :(dummy_stmt))
            e = BorrowCheckError(Any, [v])

            s = sprint(showerror, e)
            @test occursin("SENTINEL_REPL_LINE", s)
        end

        if isdefined(Base, :active_repl)
            try
                Base.active_repl = old_repl
            catch
            end
        end
    end
end
