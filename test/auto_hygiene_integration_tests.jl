@testitem "Auto @safe hygiene and tracking" tags = [:auto] begin
    using TestItems
    using BorrowChecker: @safe

    @testset "macro hygiene: no unqualified BorrowChecker reference" begin
        user_mod = Module(:_BCHygieneUser)

        Core.eval(user_mod, :(using BorrowChecker: @safe))

        ex = :(@safe function f(x)
            y = x
            return y
        end)

        expanded = macroexpand(user_mod, ex)

        function has_unqualified_borrowchecker_ref(node)
            if node === :BorrowChecker
                return true
            end
            if node isa Expr
                return any(has_unqualified_borrowchecker_ref, node.args)
            end
            return false
        end

        # Fully-qualified `GlobalRef(BorrowChecker, ...)` references are fine:
        # the macro must not require an unqualified `BorrowChecker` binding in
        # the user's module.
        @test !has_unqualified_borrowchecker_ref(expanded)
    end

    @testset "runtime hygiene: no `BorrowChecker` binding needed" begin
        user_mod = Module(:_BCHygieneRuntimeUser)
        Core.eval(user_mod, :(using BorrowChecker: @safe))
        Core.eval(user_mod, :(@safe function f(x)
            y = x
            return y
        end))
        @test Core.eval(user_mod, :(f([1, 2, 3]))) == [1, 2, 3]
    end

    @testset "is_tracked_type doesn't error on abstract" begin
        # Regression: fieldtypes(fieldcount) throws for abstract types.
        @test BorrowChecker.is_tracked_type(AbstractArray) === true
        @test BorrowChecker.is_tracked_type(AbstractVector) === true
    end
end
