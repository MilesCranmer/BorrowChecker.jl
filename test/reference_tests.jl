using TestItems
using BorrowChecker

@testitem "Immutable References" begin
    using BorrowChecker: is_moved

    @bind :mut x = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = x
        @test ref == [1, 2, 3]  # Can read through reference
        @test !is_moved(x)  # Reference doesn't move ownership
        @test_throws BorrowRuleError ref[1] = 10  # Can't modify through immutable ref
        @ref lt ref2 = x
        @test ref2 == [1, 2, 3]  # Original unchanged
    end
end

@testitem "Property access through references" begin
    struct Point
        x::Int
        y::Int
    end
    @bind p = Point(1, 2)
    @test p isa Bound{Point}
    @lifetime lt begin
        @ref lt ref_p = p
        @test ref_p isa Borrowed{Point}
        @test ref_p.x isa Borrowed{Int}
        # Ref to ref:
        @ref lt rrx = ref_p.x
        @test rrx == 1
        @test ref_p.x == 1  # Can read properties
        @test_throws BorrowRuleError ref_p.x = 10  # Can't modify properties
    end
    @test p.immutable_borrows == 0
    @bind :mut mp = Point(1, 2)
    @lifetime lt begin
        @ref lt :mut mut_ref_p = mp
        @test_throws "Cannot create mutable reference: value is already mutably borrowed" mut_ref_p.x ==
            1
        @test_throws ErrorException mut_ref_p.x = 10  # Can't modify immutable struct properties
    end
end

@testitem "Mutable Property Access" begin
    @bind :mut y = [1, 2, 3]
    @lifetime lt begin
        @ref lt :mut mut_ref = y
        @test mut_ref == [1, 2, 3]  # Can read through reference
        push!(mut_ref, 4)  # Can modify through mutable reference

        @test_throws BorrowRuleError @ref lt d = y
        @test_throws(
            "Cannot create immutable reference: value is mutably borrowed", @ref lt d = y
        )
    end
end

@testitem "Referencing moved values" begin
    @bind z = [1, 2, 3]
    @move w = z
    @lifetime lt begin
        @test_throws MovedError @ref lt d = z
        @test_throws BorrowRuleError @ref lt :mut d = z
    end
end

@testitem "Lifetime Blocks" begin
    # Test multiple immutable references
    @bind x = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref1 = x
        @ref lt ref2 = x
        @test ref1 == [1, 2, 3]
        @test ref2 == [1, 2, 3]
        @test x.immutable_borrows == 2

        # Can't create mutable reference while immutably borrowed
        @test_throws BorrowRuleError @ref lt :mut d = x
    end
    @test x.immutable_borrows == 0  # All borrows cleaned up

    # Test mutable reference blocks
    @bind :mut y = [1, 2, 3]
    @bind :mut z = [4, 5, 6]
    @lifetime lt begin
        @ref lt :mut mut_ref1 = y
        # Can't create another mutable reference to y
        @test_throws BorrowRuleError @ref lt :mut d = y
        # Can't create immutable reference to y while mutably borrowed
        @test_throws BorrowRuleError @ref lt d = y

        # But can create references to different variables
        @ref lt :mut mut_ref2 = z
        push!(mut_ref1, 4)
        push!(mut_ref2, 7)
    end
    @test y.mutable_borrows == 0  # Borrows cleaned up
    @test z.mutable_borrows == 0
    @test y == [1, 2, 3, 4]  # Modifications persisted
    @test z == [4, 5, 6, 7]

    # Test mixing mutable and immutable references to different variables
    @bind :mut a = [1, 2, 3]
    @bind b = [4, 5, 6]
    @lifetime lt begin
        @ref lt :mut mut_ref = a
        @ref lt imm_ref = b
        push!(mut_ref, 4)
        @test imm_ref == [4, 5, 6]
        @test_throws "Cannot write to immutable reference" push!(imm_ref, 7)
    end
    @test a == [1, 2, 3, 4]
    @test b == [4, 5, 6]
end

@testitem "Lifetime Let Blocks" begin
    # Test lifetime with let block
    @bind :mut outer = [1, 2, 3]

    @lifetime lt let
        @ref lt :mut inner = outer
        push!(inner, 4)
        @test inner == [1, 2, 3, 4]
    end

    # Test that borrows are cleaned up after let block
    @test outer.mutable_borrows == 0
    @test outer == [1, 2, 3, 4]
end

@testitem "Prevents write on mutable array when referenced" begin
    @bind :mut x = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = x
        @test_throws BorrowRuleError x[1] = 5
    end
end
