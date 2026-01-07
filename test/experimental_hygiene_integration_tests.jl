@testitem "Experimental @borrow_checker hygiene and tracking" tags=[:unstable] begin
    using TestItems
    using BorrowChecker

    VERSION >= v"1.14.0-" ||
        error("This test requires Julia >= 1.14.0- (BorrowChecker.Experimental).")

    @testset "macro hygiene: no BorrowChecker global" begin
        user_mod = Module(:_BCHygieneUser)

        Core.eval(user_mod, :(using BorrowChecker.Experimental: @borrow_checker))

        ex = :(@borrow_checker function f(x)
            y = x
            return y
        end)

        expanded = macroexpand(user_mod, ex)

        function has_borrowchecker_ref(node)
            if node === :BorrowChecker
                return true
            end
            if node isa GlobalRef
                return nameof(node.mod) === :BorrowChecker
            end
            if node isa Expr
                return any(has_borrowchecker_ref, node.args)
            end
            return false
        end

        @test !has_borrowchecker_ref(expanded)
    end

    @testset "is_tracked_type doesn't error on abstract" begin
        # Regression: fieldtypes(fieldcount) throws for abstract types.
        @test BorrowChecker.Experimental.is_tracked_type(AbstractArray) === true
        @test BorrowChecker.Experimental.is_tracked_type(AbstractVector) === true
    end
end
