using TestItems
using TestItemRunner
using BorrowCheck

@run_package_tests

@testitem "Basic Ownership" begin
    # Create owned value
    @own x = 42
    @lifetime lt begin
        ref = @ref lt x
        @test ref == 42
        @test !x.moved
    end

    # Create mutable owned value
    @own_mut y = [1, 2, 3]
    @lifetime lt begin
        ref = @ref lt y
        @test ref == [1, 2, 3]
        @test !y.moved
    end
end

@testitem "Move Semantics" begin
    # Basic move with @move y = x syntax
    @own x = [1, 2, 3]
    @move y = x
    @lifetime lt begin
        ref = @ref lt y
        @test ref == [1, 2, 3]
        @test x.moved
        @test !y.moved
        @test_throws MovedError @ref lt x
    end

    # Alternative move syntax y = @move x
    @own p = [4, 5, 6]
    q = @move p
    @lifetime lt begin
        ref = @ref lt q
        @test ref == [4, 5, 6]
        @test p.moved
        @test !q.moved
        @test_throws MovedError @ref lt p
    end

    # Cannot move twice
    @test_throws MovedError @move z = x

    # Can move multiple times through chain
    @own a = [1, 2, 3]
    @move b = a
    @move c = b
    @lifetime lt begin
        ref = @ref lt c
        @test ref == [1, 2, 3]
        @test a.moved && b.moved && !c.moved
        @test_throws MovedError @ref lt a
        @test_throws MovedError @ref lt b
    end
end

@testitem "Primitive Types" begin
    # Primitives still follow move semantics for consistency
    @own x = 42
    @move y = x
    @lifetime lt begin
        ref = @ref lt y
        @test ref[] == 42
        @test_throws MovedError @ref lt x
    end
end

@testitem "Immutable References" begin
    @own x = [1, 2, 3]
    @lifetime lt begin
        ref = @ref lt x
        @test ref == [1, 2, 3]  # Can read through reference
        @test !x.moved  # Reference doesn't move ownership
        @test_throws BorrowRuleError ref[1] = 10  # Can't modify through immutable ref
        ref2 = @ref lt x
        @test ref2 == [1, 2, 3]  # Original unchanged
    end
end

@testitem "Property access through references" begin
    struct Point
        x::Int
        y::Int
    end
    @own p = Point(1, 2)
    @test p isa Owned{Point}
    @lifetime lt begin
        ref_p = @ref lt p
        @test ref_p isa Borrowed{Point}
        @test ref_p.x isa Borrowed{Int}
        rx = ref_p.x
        @test ref_p.x == 1  # Can read properties
        @test_throws BorrowRuleError ref_p.x = 10  # Can't modify properties
    end
    @own_mut mp = Point(1, 2)
    @lifetime lt begin
        mut_ref_p = @ref_mut lt mp
        @test mut_ref_p.x == 1  # Can read properties
        @test_throws ErrorException mut_ref_p.x = 10  # Can't modify immutable struct properties
    end
end

@testitem "Mutable Property Access" begin
    @own_mut y = [1, 2, 3]
    @lifetime lt begin
        mut_ref = @ref_mut lt y
        @test mut_ref == [1, 2, 3]  # Can read through reference
        push!(mut_ref, 4)  # Can modify through mutable reference

        @test_throws BorrowRuleError @ref lt y
        @test_throws(
            "Cannot create immutable reference: value is mutably borrowed",
            @ref lt y
        )
    end
end

@testitem "Referencing moved values" begin
    @own z = [1, 2, 3]
    @move w = z
    @lifetime lt begin
        @test_throws MovedError @ref lt z
        @test_throws MovedError @ref_mut lt z
    end
end

@testitem "Function Ownership" begin
    # Helper function that takes ownership
    function consume_vector(v::Vector{Int})
        push!(v, 4)
        v
    end

    # Test taking ownership in function calls
    @own x = [1, 2, 3]
    @own result = consume_vector(@take x)
    @test result == [1, 2, 3, 4]
    @test x.moved
    @lifetime lt begin
        @test_throws MovedError @ref lt x
    end

    # Can't take ownership twice
    @test_throws MovedError consume_vector(@take x)

    # Test borrowing in function calls
    function borrow_vector(v)
        @test v == [1, 2, 3]
    end

    @own y = [1, 2, 3]
    @lifetime lt begin
        borrow_vector(@ref lt y)  # Immutable borrow
        @test !y.moved  # y is still valid
        ref = @ref lt y
        @test ref == [1, 2, 3]
    end

    # Test mutable borrowing
    function modify_vector(v)
        push!(v, 4)
    end

    @own_mut z = [1, 2, 3]
    @lifetime lt begin
        modify_vector(@ref_mut lt z)  # Mutable borrow
        @test !z.moved  # z is still valid
    end
    @lifetime lt begin
        ref = @ref lt z
        @test ref == [1, 2, 3, 4]
    end
end

@testitem "Assignment Syntax" begin
    # Test normal assignment with @set on mutable
    @own_mut x = [1, 2, 3]
    @set x = [4, 5, 6]
    @lifetime lt begin
        ref = @ref lt x
        @test ref == [4, 5, 6]
    end

    # Test assignment to immutable fails
    @own y = [1, 2, 3]
    @test_throws BorrowRuleError @set y = [4, 5, 6]

    # Test assignment after move
    @own_mut z = [1, 2, 3]
    @move w = z
    @test_throws MovedError @set z = [4, 5, 6]

    # Test assignment with references
    @own_mut v = [1, 2, 3]
    @lifetime lt begin
        ref = @ref_mut lt v
        push!(ref, 4)
        @test_throws("Cannot assign to value while borrowed", @set v = [5, 6, 7])
    end
    @set v = [5, 6, 7]
    @lifetime lt begin
        ref = @ref lt v
        @test ref == [5, 6, 7]
        @test_throws "Cannot write to immutable reference" ref[1] = [8]
    end
end

@testitem "Lifetime Blocks" begin
    # Test multiple immutable references
    @own x = [1, 2, 3]
    @lifetime lt begin
        ref1 = @ref lt x
        ref2 = @ref lt x
        @test ref1 == [1, 2, 3]
        @test ref2 == [1, 2, 3]
        @test x.immutable_borrows == 2

        # Can't create mutable reference while immutably borrowed
        @test_throws BorrowRuleError @ref_mut lt x
    end
    @test x.immutable_borrows == 0  # All borrows cleaned up

    # Test mutable reference blocks
    @own_mut y = [1, 2, 3]
    @own_mut z = [4, 5, 6]
    @lifetime lt begin
        mut_ref1 = @ref_mut lt y
        # Can't create another mutable reference to y
        @test_throws BorrowRuleError @ref_mut lt y
        # Can't create immutable reference to y while mutably borrowed
        @test_throws BorrowRuleError @ref lt y

        # But can create references to different variables
        mut_ref2 = @ref_mut lt z
        push!(mut_ref1, 4)
        push!(mut_ref2, 7)
    end
    @test y.mutable_borrows == 0  # Borrows cleaned up
    @test z.mutable_borrows == 0
    @test y == [1, 2, 3, 4]  # Modifications persisted
    @test z == [4, 5, 6, 7]


    # Test mixing mutable and immutable references to different variables
    @own_mut a = [1, 2, 3]
    @own b = [4, 5, 6]
    @lifetime lt begin
        mut_ref = @ref_mut lt a
        imm_ref = @ref lt b
        push!(mut_ref, 4)
        @test imm_ref == [4, 5, 6]
        @test_throws "Cannot write to immutable reference" push!(imm_ref, 7)
    end
    @test a == [1, 2, 3, 4]
    @test b == [4, 5, 6]
end
