using TestItems
using BorrowChecker

@testitem "Immutable References" begin
    using BorrowChecker: is_moved

    @own :mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ~lt ref = x
        @test ref == [1, 2, 3]  # Can read through reference
        @test !is_moved(x)  # Reference doesn't move ownership
        @test_throws BorrowRuleError ref[1] = 10  # Can't modify through immutable ref
        @ref ~lt ref2 = x
        @test ref2 == [1, 2, 3]  # Original unchanged
    end
end

@testitem "Expired references" begin
    @own x = [42]
    y = Any[]
    @lifetime lt begin
        @ref ~lt ref = x
        push!(y, ref)
    end
    @test_throws ExpiredError y[1][1]

    # Also test showerror coverage
    err = try
        y[1][1]
    catch e
        e
    end
    output = sprint(io -> showerror(io, err))
    @test occursin("value's lifetime has expired", output)
end

@testitem "Property access through references" begin
    using BorrowChecker: get_immutable_borrows

    struct Point
        x::Int
        y::Int
    end
    @own p = Point(1, 2)
    @test p isa Owned{Point}
    @lifetime lt begin
        @ref ~lt ref_p = p
        @test ref_p isa Borrowed{Point}
        @test ref_p.x isa LazyAccessor{Int}
        # Ref to ref:
        @ref ~lt rrx = ref_p.x
        @test rrx == 1
        @test ref_p.x == 1  # Can read properties
        @test_throws BorrowRuleError ref_p.x = 10  # Can't modify properties
    end
    @test get_immutable_borrows(p) == 0
    @own :mut mp = Point(1, 2)
    @lifetime lt begin
        @ref ~lt :mut mut_ref_p = mp
        @test mut_ref_p.x == 1
    end
end

@testitem "Mutable Property Access" begin
    @own :mut y = [1, 2, 3]
    @lifetime lt begin
        @ref ~lt :mut mut_ref = y
        @test mut_ref == [1, 2, 3]  # Can read through reference
        push!(mut_ref, 4)  # Can modify through mutable reference

        @test_throws BorrowRuleError @ref ~lt d = y
        @test_throws(
            "Cannot create immutable reference: `y` is mutably borrowed", @ref ~lt d = y
        )
    end
end

@testitem "Referencing moved values" begin
    @own z = [1, 2, 3]
    @move w = z
    @lifetime lt begin
        @test_throws MovedError @ref ~lt d = z
        @test_throws BorrowRuleError @ref ~lt :mut d = z
    end
end

@testitem "Lifetime Blocks" begin
    using BorrowChecker: get_immutable_borrows, get_mutable_borrows

    # Test multiple immutable references
    @own x = [1, 2, 3]
    @lifetime lt begin
        @ref ~lt ref1 = x
        @ref ~lt ref2 = x
        @test ref1 == [1, 2, 3]
        @test ref2 == [1, 2, 3]
        @test get_immutable_borrows(x) == 2

        # Can't create mutable reference while immutably borrowed
        @test_throws BorrowRuleError @ref ~lt :mut d = x
    end
    @test get_immutable_borrows(x) == 0  # All borrows cleaned up

    # Test mutable reference blocks
    @own :mut y = [1, 2, 3]
    @own :mut z = [4, 5, 6]
    @lifetime lt begin
        @ref ~lt :mut mut_ref1 = y
        # Can't create another mutable reference to y
        @test_throws BorrowRuleError @ref ~lt :mut d = y
        # Can't create immutable reference to y while mutably borrowed
        @test_throws BorrowRuleError @ref ~lt d = y

        # But can create references to different variables
        @ref ~lt :mut mut_ref2 = z
        push!(mut_ref1, 4)
        push!(mut_ref2, 7)
    end
    @test get_mutable_borrows(y) == 0  # Borrows cleaned up
    @test get_mutable_borrows(z) == 0
    @test y == [1, 2, 3, 4]  # Modifications persisted
    @test z == [4, 5, 6, 7]

    # Test mixing mutable and immutable references to different variables
    @own :mut a = [1, 2, 3]
    @own b = [4, 5, 6]
    @lifetime lt begin
        @ref ~lt :mut mut_ref = a
        @ref ~lt imm_ref = b
        push!(mut_ref, 4)
        @test imm_ref == [4, 5, 6]
        @test_throws "Cannot write to immutable reference `imm_ref`" push!(imm_ref, 7)
    end
    @test a == [1, 2, 3, 4]
    @test b == [4, 5, 6]
end

@testitem "Lifetime Let Blocks" begin
    using BorrowChecker: get_mutable_borrows

    # Test lifetime with let block
    @own :mut outer = [1, 2, 3]

    @lifetime lt let
        @ref ~lt :mut inner = outer
        push!(inner, 4)
        @test inner == [1, 2, 3, 4]
    end

    # Test that borrows are cleaned up after let block
    @test get_mutable_borrows(outer) == 0
    @test outer == [1, 2, 3, 4]
end

@testitem "Prevents write on mutable array when referenced" begin
    @own :mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ~lt ref = x
        @test_throws BorrowRuleError x[1] = 5
    end
end

@testitem "Editing a vector in a struct" begin
    using BorrowChecker: is_moved

    struct Container
        x::Vector{Int}
    end

    @own :mut c = Container([1, 2, 3])
    c.x[1] = 4
    @test c.x == [4, 2, 3]

    # When we pass the inner vector, the outer
    # container is moved.
    f(x::Vector) = sum(x)
    @test f(@take! c.x) == 9
    @test is_moved(c)
end

@testitem "Tuple unpacking with references" begin
    # Test basic immutable references
    @own x = [1]
    @own y = [2]
    @own z = [3]
    @lifetime lt begin
        @ref ~lt (rx, ry, rz) = (x, y, z)
        @test rx == [1]
        @test ry == [2]
        @test rz == [3]

        # Can create multiple immutable references
        @ref ~lt (rx2, ry2, rz2) = (x, y, z)
        @test rx2 == [1]
    end

    # Need to pass tuple on both sides
    @test_throws(
        "Cannot mix tuple and non-tuple arguments in @ref", @eval @ref ~lt (a, b, c) = d
    )
    @test_throws(
        "Cannot mix tuple and non-tuple arguments in @ref", @eval @ref ~lt a = (b, c, d)
    )
    @test_throws(
        "Number of variables must match number of values in tuple unpacking",
        @eval @ref ~lt (a, b) = (c, d, e, f)
    )

    # Test mutable references
    @own :mut mx = [1]
    @own :mut my = [2]
    @own :mut mz = [3]
    @lifetime lt begin
        @ref ~lt :mut (rmx, rmy, rmz) = (mx, my, mz)
        push!(rmx, 4)
        push!(rmy, 5)
        push!(rmz, 6)

        # Can't create second mutable reference while first exists
        @test_throws BorrowRuleError @ref ~lt :mut (rx2, ry2, rz2) = (mx, my, mz)

        # Can't create immutable reference while mutable exists
        @test_throws BorrowRuleError @ref ~lt (rx2, ry2, rz2) = (mx, my, mz)
    end

    @test mx == [1, 4]
    @test my == [2, 5]
    @test mz == [3, 6]
end

@testitem "Field/index re-borrow via LazyAccessor" begin
    mutable struct A
        a::Int
    end
    @own :mut x = A(1)
    @lifetime L1 begin
        @ref ~L1 :mut r = x
        @lifetime L2 begin
            @ref ~L2 r2 = r.a
            @test r2 == 1
            @test_throws BorrowRuleError r.a = 7
        end
        r.a = 7            # freeze lifted
    end
    @test x.a == 7
end

@testitem "Sibling lifetimes don't interfere" begin
    @own :mut v = [1, 2, 3]
    @lifetime L1 begin
        @ref ~L1 :mut r1 = v
        @lifetime L2a begin
            @ref ~L2a r2 = r1
        end
        @lifetime L2b begin
            @ref ~L2b r3 = r1
        end
        @test_throws BorrowRuleError v[1]
    end
end

@testitem "Mixed owned / borrowed fields" begin
    mutable struct Box
        data::Vector{Int}
    end
    @own :mut bx = Box([1, 2])
    @lifetime outer begin
        @ref ~outer :mut bx_ref = bx
        @lifetime mid begin
            @ref ~mid data_ref = bx_ref.data
            @test data_ref == [1, 2]
            @test_throws BorrowRuleError begin
                @lifetime inner begin
                    @ref ~inner :mut fail_mut = bx
                end
            end
        end
    end
end

@testitem "Re-borrow inside comprehension keeps frozen" begin
    @own :mut numbers = [1, 2, 3, 4]
    @lifetime L1 begin
        @ref ~L1 r = numbers
        total = @lifetime L2 begin
            sum(@ref(~L2, x = i) for i in r)
        end
        @test total == 10
        @test_throws BorrowRuleError r[1] = 99
    end
end

@testitem "New mutable borrow in nested lifetime is forbidden" begin
    @own :mut v = [1, 2]
    @lifetime L1 begin
        @ref ~L1 :mut r = v
        @lifetime L2 begin
            @test_throws BorrowRuleError @ref ~L2 :mut bad = r
        end
    end
end

@testitem "Move still respects freeze" begin
    @own :mut n = [1]
    @lifetime L1 begin
        @ref ~L1 :mut r = n
        @lifetime L2 begin
            @ref ~L2 r2 = r
            @test r2[1] == 1
            @test_throws BorrowRuleError @move m = n
        end
    end
end

@testitem "Exception inside inner lifetime unwinds counters" begin
    @own :mut v = [0]
    try
        @lifetime L1 begin
            @ref ~L1 :mut r = v
            @lifetime L2 begin
                @ref ~L2 r2 = r
                error("boom")
            end
        end
    catch e
        @test occursin("boom", sprint(showerror, e))
    end
    # Even after exception, freeze must be cleared
    @lifetime final begin
        @ref ~final :mut r_final = v
        r_final[1] = 5
    end
    @test v[1] == 5
end

@testitem "`@bc` should automatically downgrade to immutable borrow" begin
    @own :mut x = [1, 2, 3]
    f!(y::@&(:mut, Vector{Int})) = (y[1] += 1; nothing)

    @test_throws MethodError @bc f!(x)
    @bc f!(@mut(x))
    @test x == [2, 2, 3]

    @lifetime lt begin
        @ref ~lt :mut r = x
        @test_throws MethodError @bc f!(r)
        @bc f!(@mut(r))
        @test r == [3, 2, 3]
    end
end

@testitem "`@bc` automatic downgrade even with LazyAccessor" begin
    mutable struct A
        a::Vector{Int}
    end
    @own :mut x = A([1])

    @lifetime lt begin
        @ref ~lt :mut r = x
        @test typeof(r.a) <: BorrowChecker.LazyAccessorOf{<:BorrowedMut}
        @test (@bc typeof(r.a)) <: Borrowed
    end
    @test (@bc typeof(@mut(x.a))) <: BorrowedMut
    @lifetime lt2 begin
        @ref ~lt2 r = x
        @test_throws BorrowRuleError (@bc typeof(@mut(r.a)))
    end
end
