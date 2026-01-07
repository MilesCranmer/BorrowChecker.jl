@testitem "DynamicExpressions integration" tags=[:unstable] begin
    using TestItems
    using BorrowChecker

    # This integration test exercises the experimental IR borrow checker on a
    # real external package type (DynamicExpressions.Expression).

    VERSION >= v"1.14.0-" ||
        error("This test requires Julia >= 1.14.0- (BorrowChecker.Experimental).")

    have_dynamic_expressions = true
    try
        @eval using DynamicExpressions
    catch
        have_dynamic_expressions = false
    end
    have_dynamic_expressions || (@test true; return)

    using BorrowChecker.Experimental: BorrowCheckError

    operators = OperatorEnum(1 => [exp], 2 => [+, -, *])
    x1 = Expression(Node{Float64}(feature=1); operators)
    x2 = Expression(Node{Float64}(feature=2); operators)

    BorrowChecker.Experimental.@borrow_checker bat(ex) = begin
        (c1, r1) = get_scalar_constants(ex)
        ex2 = ex
        set_scalar_constants!(ex, c1 .* 2, r1)
        ex2
    end

    @test_throws BorrowCheckError bat(x1 + x2 * 3.2)
end
