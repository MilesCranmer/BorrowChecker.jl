@testitem "Experimental @borrow_checker hygiene and tracking" tags = [:experimental] begin
    using TestItems
    using BorrowChecker.Experimental: @borrow_checker

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

    @testset "runtime hygiene: no `BorrowChecker` binding needed" begin
        user_mod = Module(:_BCHygieneRuntimeUser)
        Core.eval(user_mod, :(using BorrowChecker.Experimental: @borrow_checker))
        Core.eval(user_mod, :(@borrow_checker function f(x)
            y = x
            return y
        end))
        @test Core.eval(user_mod, :(f([1, 2, 3]))) == [1, 2, 3]
    end

    @testset "is_tracked_type doesn't error on abstract" begin
        # Regression: fieldtypes(fieldcount) throws for abstract types.
        @test BorrowChecker.Experimental.is_tracked_type(AbstractArray) === true
        @test BorrowChecker.Experimental.is_tracked_type(AbstractVector) === true
    end
end
