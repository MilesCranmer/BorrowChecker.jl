@testitem "Experimental borrow checker printing" tags = [:unstable] begin
    using TestItems
    using BorrowChecker

    # This test targets error printing helpers in the experimental borrow checker.
    using BorrowChecker.Experimental: BorrowCheckError, BorrowViolation

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
end
