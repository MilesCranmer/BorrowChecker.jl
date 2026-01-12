@testitem "DynamicExpressions integration" tags = [:experimental] begin
    using TestItems
    using BorrowChecker

    # This integration test exercises the experimental IR borrow checker on a
    # real external package type (DynamicExpressions.Expression).

    using DynamicExpressions
    using BorrowChecker.Auto: BorrowCheckError

    operators = OperatorEnum(1 => [exp], 2 => [+, -, *])
    x1 = Expression(Node{Float64}(; feature=1); operators)
    x2 = Expression(Node{Float64}(; feature=2); operators)

    BorrowChecker.Auto.@auto bat(ex) = begin
        (c1, r1) = get_scalar_constants(ex)
        ex2 = ex
        set_scalar_constants!(ex, c1 .* 2, r1)
        ex2
    end

    @test_throws BorrowCheckError bat(x1 + x2 * 3.2)
end
