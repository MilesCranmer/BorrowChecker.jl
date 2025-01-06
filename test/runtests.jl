using TestItems
using TestItemRunner
using BorrowChecker

@run_package_tests

@testitem "Basic Ownership" begin
    # Create owned value
    @own x = 42
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == 42
        @test !x.moved
    end

    # Create mutable owned value
    @own_mut y = [1, 2, 3]
    @lifetime lt begin
        @ref ref = y in lt
        @test ref == [1, 2, 3]
        @test !y.moved
    end
end

@testitem "Move Semantics" begin
    # Basic move with @move y = x syntax
    @own x = [1, 2, 3]
    @move y = x
    @lifetime lt begin
        @ref ref = y in lt
        @test ref == [1, 2, 3]
        @test x.moved
        @test !y.moved
        @test_throws MovedError @ref d = x in lt
    end

    # Cannot move twice
    @test_throws MovedError @move z = x

    # Can move multiple times through chain
    @own a = [1, 2, 3]
    @move b = a
    @move c = b
    @lifetime lt begin
        @ref ref = c in lt
        @test ref == [1, 2, 3]
        @test a.moved && b.moved && !c.moved
        @test_throws MovedError @ref d = a in lt
        @test_throws MovedError @ref d = b in lt
    end
end

@testitem "Primitive Types" begin
    # Primitives still follow move semantics for consistency
    @own x = 42
    @move y = x
    @lifetime lt begin
        @ref ref = y in lt
        @test ref == 42
        @test_throws MovedError @ref d = x in lt
    end
end

@testitem "Immutable References" begin
    @own x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == [1, 2, 3]  # Can read through reference
        @test !x.moved  # Reference doesn't move ownership
        @test_throws BorrowRuleError ref[1] = 10  # Can't modify through immutable ref
        @ref ref2 = x in lt
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
        @ref ref_p = p in lt
        @test ref_p isa Borrowed{Point}
        @test ref_p.x isa Borrowed{Int}
        # Ref to ref:
        @ref rrx = ref_p.x in lt
        @test rrx == 1
        @test ref_p.x == 1  # Can read properties
        @test_throws BorrowRuleError ref_p.x = 10  # Can't modify properties
    end
    @test p.immutable_borrows == 0
    @own_mut mp = Point(1, 2)
    @lifetime lt begin
        @ref_mut mut_ref_p = mp in lt
        @test_throws "Cannot create mutable reference: value is already mutably borrowed" mut_ref_p.x ==
            1
        @test_throws ErrorException mut_ref_p.x = 10  # Can't modify immutable struct properties
    end
end

@testitem "Mutable Property Access" begin
    @own_mut y = [1, 2, 3]
    @lifetime lt begin
        @ref_mut mut_ref = y in lt
        @test mut_ref == [1, 2, 3]  # Can read through reference
        push!(mut_ref, 4)  # Can modify through mutable reference

        @test_throws BorrowRuleError @ref d = y in lt
        @test_throws(
            "Cannot create immutable reference: value is mutably borrowed", @ref d = y in lt
        )
    end
end

@testitem "Referencing moved values" begin
    @own z = [1, 2, 3]
    @move w = z
    @lifetime lt begin
        @test_throws MovedError @ref d = z in lt
        @test_throws BorrowRuleError @ref_mut d = z in lt
    end
end

@testitem "Function Ownership" begin
    # Helper function that takes ownership
    function consume_vector(v::Vector{Int})
        push!(v, 4)
        return v
    end

    # Test taking ownership in function calls
    @own x = [1, 2, 3]
    @own result = consume_vector(@take x)
    @test result == [1, 2, 3, 4]
    @test x.moved
    @lifetime lt begin
        @test_throws MovedError @ref d = x in lt
    end

    # Can't take ownership twice
    @test_throws MovedError consume_vector(@take x)

    # Test borrowing in function calls
    function borrow_vector(v)
        @test v == [1, 2, 3]
    end

    @own y = [1, 2, 3]
    @lifetime lt begin
        @ref ref = y in lt  # Immutable borrow
        @test !y.moved  # y is still valid
        @ref ref2 = y in lt
        @test ref2 == [1, 2, 3]
    end

    # Test mutable borrowing
    function modify_vector(v)
        return push!(v, 4)
    end

    @own_mut z = [1, 2, 3]
    @lifetime lt begin
        @ref_mut ref = z in lt  # Mutable borrow
        push!(ref, 4)
        @test !z.moved  # z is still valid
    end
    @lifetime lt begin
        @ref ref = z in lt
        @test ref == [1, 2, 3, 4]
    end
end

@testitem "Assignment Syntax" begin
    # Test normal assignment with @set on mutable
    @own_mut x = [1, 2, 3]
    @set x = [4, 5, 6]
    @lifetime lt begin
        @ref ref = x in lt
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
        @ref_mut ref = v in lt
        push!(ref, 4)
        @test_throws("Cannot assign to value while borrowed", @set v = [5, 6, 7])
    end
    @set v = [5, 6, 7]
    @lifetime lt begin
        @ref ref = v in lt
        @test ref == [5, 6, 7]
        @test_throws "Cannot write to immutable reference" ref[1] = [8]
    end
end

@testitem "Lifetime Blocks" begin
    # Test multiple immutable references
    @own x = [1, 2, 3]
    @lifetime lt begin
        @ref ref1 = x in lt
        @ref ref2 = x in lt
        @test ref1 == [1, 2, 3]
        @test ref2 == [1, 2, 3]
        @test x.immutable_borrows == 2

        # Can't create mutable reference while immutably borrowed
        @test_throws BorrowRuleError @ref_mut d = x in lt
    end
    @test x.immutable_borrows == 0  # All borrows cleaned up

    # Test mutable reference blocks
    @own_mut y = [1, 2, 3]
    @own_mut z = [4, 5, 6]
    @lifetime lt begin
        @ref_mut mut_ref1 = y in lt
        # Can't create another mutable reference to y
        @test_throws BorrowRuleError @ref_mut d = y in lt
        # Can't create immutable reference to y while mutably borrowed
        @test_throws BorrowRuleError @ref d = y in lt

        # But can create references to different variables
        @ref_mut mut_ref2 = z in lt
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
        @ref_mut mut_ref = a in lt
        @ref imm_ref = b in lt
        push!(mut_ref, 4)
        @test imm_ref == [4, 5, 6]
        @test_throws "Cannot write to immutable reference" push!(imm_ref, 7)
    end
    @test a == [1, 2, 3, 4]
    @test b == [4, 5, 6]
end

@testitem "Lifetime Let Blocks" begin
    # Test lifetime with let block
    @own_mut outer = [1, 2, 3]

    @lifetime lt let
        @ref_mut inner = outer in lt
        push!(inner, 4)
        @test inner == [1, 2, 3, 4]
    end

    # Test that borrows are cleaned up after let block
    @test outer.mutable_borrows == 0
    @test outer == [1, 2, 3, 4]
end

@testitem "mutability check works" begin
    using BorrowChecker: recursive_ismutable

    @test !recursive_ismutable(Int)
    @test recursive_ismutable(Vector{Int})
end

@testitem "Borrowed Arrays" begin
    @own x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == [1, 2, 3]
        # We can borrow the borrow since it is immutable
        @ref ref2 = ref in lt
        @test ref2 == [1, 2, 3]
        @test ref2 isa Borrowed{Vector{Int}}
        @test ref2[2] == 2
        @test ref2[2] isa Borrowed{Int}

        @test ref2[1:2] isa Borrowed{Vector{Int}}

        # No mutating allowed
        @test_throws BorrowRuleError push!(ref2, 4)
    end
    @test x == [1, 2, 3]
end

@testitem "Symbol Tracking" begin
    # Test symbol tracking for owned values
    @own x = 42
    @test x.symbol == :x

    @own_mut y = [1, 2, 3]
    @test y.symbol == :y

    # Test symbol tracking through moves
    @move z = x
    # Gets new symbol when moved
    @test z.symbol == :z
    @test x.symbol == :x
    @test !z.moved
    @test x.moved

    # Test error messages include the correct symbol
    err = try
        @move w = x
        nothing
    catch e
        e
    end
    @test err isa MovedError
    @test err.var === :x

    # Test symbol tracking in references
    @lifetime lt begin
        @ref ref = y in lt
        @test y.symbol == :y  # Original symbol preserved
        @test ref.owner.symbol == :y
    end
end

@testitem "Prevents write on mutable array when referenced" begin
    @own_mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        @test_throws BorrowRuleError x[1] = 5
    end
end
