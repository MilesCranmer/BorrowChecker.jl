using TestItems
using BorrowChecker

@testitem "Basic Ownership" begin
    using BorrowChecker: is_moved

    # Create owned value
    @bind x = 42
    @lifetime lt begin
        @ref lt ref = x
        @test ref == 42
        @test !is_moved(x)
    end

    # Create mutable owned value
    @bind :mut y = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = y
        @test ref == [1, 2, 3]
        @test !is_moved(y)
    end
end

@testitem "Move Semantics" begin
    using BorrowChecker: is_moved

    # Basic move with @move y = x syntax
    @bind x = [1, 2, 3]
    @move y = x  # Move to immutable
    @lifetime lt begin
        @ref lt ref = y
        @test ref == [1, 2, 3]
        @test is_moved(x)
        @test !is_moved(y)
        @test_throws MovedError @ref lt d = x
    end

    # Cannot move twice
    @test_throws MovedError @move z = x

    # Can move multiple times through chain
    @bind a = [1, 2, 3]
    @move :mut y = a  # Move to mutable
    @move z = y  # Move to immutable
    @lifetime lt begin
        @ref lt ref = z
        @test ref == [1, 2, 3]
        @test is_moved(a) && is_moved(y) && !is_moved(z)
        @test_throws MovedError @ref lt d = a
        @test_throws MovedError @ref lt d = y
    end
end

@testitem "Primitive Types" begin
    # Primitives are isbits types, so they are cloned rather than moved
    @bind x = 42
    @move y = x
    @lifetime lt begin
        @ref lt ref = y
        @test ref == 42
        # x is still valid since it was cloned:
        @ref lt ref2 = x
        @test ref2 == 42
    end

    # Same with @take
    @bind z = 42
    @test (@take z) == 42
    @lifetime lt begin
        # z is still valid since it was cloned:
        @ref lt ref = z
        @test ref == 42
    end
end

@testitem "mutability check works" begin
    @test isbitstype(Int)
    @test !isbitstype(Vector{Int})
end

@testitem "Mutability changes through moves" begin
    using BorrowChecker: is_moved

    # Test moving from immutable to mutable
    @bind x = [1, 2, 3]
    @test_throws BorrowRuleError push!(x, 4)  # Can't modify immutable
    @move :mut y = x  # Move to mutable
    push!(y, 4)  # Can modify after move
    @test y == [1, 2, 3, 4]
    @test is_moved(x)

    # Test moving from mutable to immutable
    @bind :mut z = [1, 2, 3]
    push!(z, 4)  # Can modify mutable
    @move w = z  # Move to immutable
    @test_throws BorrowRuleError push!(w, 5)  # Can't modify after move to immutable
    @test is_moved(z)
    @test w == [1, 2, 3, 4]

    # Test chain of mutability changes
    @bind a = [1]
    @move :mut b = a  # immutable -> mutable
    push!(b, 2)
    @move c = b  # mutable -> immutable
    @test_throws BorrowRuleError push!(c, 3)
    @move :mut d = c  # immutable -> mutable
    push!(d, 3)
    @test d == [1, 2, 3]
    @test is_moved(a) && is_moved(b) && is_moved(c) && !is_moved(d)
end

@testitem "Basic clone semantics" begin
    using BorrowChecker: is_moved

    @bind x = [1, 2, 3]
    @clone y = x  # Clone to immutable
    @test y == [1, 2, 3]
    @test !is_moved(x)  # Original not moved
    @test x == [1, 2, 3]  # Original unchanged
    @test_throws BorrowRuleError push!(y, 4)  # Can't modify immutable clone
end

@testitem "Clone to mutable" begin
    using BorrowChecker: is_moved
    @bind x = [1, 2, 3]
    @clone :mut z = x
    push!(z, 4)  # Can modify mutable clone
    @test z == [1, 2, 3, 4]
    @test x == [1, 2, 3]  # Original unchanged
    @test !is_moved(x)  # Original not moved
end

@testitem "Clone of mutable value" begin
    using BorrowChecker: is_moved

    @bind :mut a = [1, 2, 3]
    push!(a, 4)
    @clone b = a  # Clone to immutable
    @test b == [1, 2, 3, 4]
    @test !is_moved(a)  # Original not moved
    push!(a, 5)  # Can still modify original
    @test a == [1, 2, 3, 4, 5]
    @test b == [1, 2, 3, 4]  # Clone unchanged
end

@testitem "Clone of nested structures" begin
    using BorrowChecker: is_moved

    struct Point
        x::Vector{Int}
        y::Vector{Int}
    end

    @bind :mut p = Point([1], [2])
    @clone :mut q = p
    @lifetime lt begin
        # Get references to all fields we'll need
        @ref lt :mut p_x = p.x
        @ref lt :mut q_x = q.x

        # We can't yet get mutable references
        # to the fields simultaneously:
        @test_throws MovedError @ref lt :mut p_y = p.y
        @test_throws MovedError @ref lt :mut q_y = q.y
        # TODO: ^Fix this

        # Test modifying original's x
        push!(p_x, 3)
        @test p_x == [1, 3]  # Original's x modified
        @test q_x == [1]  # Clone's x unchanged

        # Test modifying clone's y
        push!(q_x, 4)
        @test p_x == [1, 3]  # Original's x unchanged
        @test q_x == [1, 4]  # Clone's x modified

        @test is_moved(p)
        @test is_moved(q)
    end

    @test_skip !is_moved(p)
    @test_skip !is_moved(q)
    # TODO: ^Fix this
end

@testitem "Clone of borrowed value" begin
    using BorrowChecker: is_moved

    @bind :mut v = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = v
        @clone w = ref  # Clone from reference
        @test w isa Bound{Vector{Int}}
        @test w == [1, 2, 3]
        @test !is_moved(v)  # Original not moved
    end
    @test !is_moved(v)
    push!(v, 4)  # Can modify original after clone
    @test v == [1, 2, 3, 4]

    # Clone of moved value should fail
    @bind x = [1, 2, 3]
    @move y = x
    @test_throws MovedError @clone z = x
end

@testitem "Complex isbits types" begin
    using BorrowChecker: is_moved

    # Create a complex isbits type
    struct Point2D
        x::Float64
        y::Float64
    end

    # Test that it is indeed isbits
    @test isbitstype(Point2D)

    # Test move behavior (should clone)
    @bind p = Point2D(1.0, 2.0)
    @move q = p
    # Actually, this cloned!
    @test !is_moved(p)
    @lifetime lt begin
        @ref lt ref_p = p
        @ref lt ref_q = q
        @test ref_p.x == 1.0
        @test ref_p.y == 2.0
        @test ref_q.x == 1.0
        @test ref_q.y == 2.0
        @test !is_moved(p)  # p is still valid since Point2D is isbits
    end

    # Test take behavior (should clone)
    @bind r = Point2D(3.0, 4.0)
    @test (@take r).x == 3.0
    @lifetime lt begin
        @ref lt ref = r
        @test ref.x == 3.0  # r is still valid since Point2D is isbits
    end
end

@testitem "Using @bind like @move" begin
    using BorrowChecker: is_moved

    @bind x = Ref(42)
    @bind y = x
    @test y isa Bound{<:Ref{Int}}
    @test is_moved(x)
    @test y[] == 42
    @test !is_moved(y)  # isbits, so not moved
end

@testitem "Borrowed objects cannot be bound" begin
    @bind x = Ref(42)
    @lifetime lt begin
        @ref lt ref = x
        @test_throws BorrowRuleError @bind y = ref
    end
end
