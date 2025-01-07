using TestItems
using TestItemRunner
using BorrowChecker

@run_package_tests

@testitem "Basic Ownership" begin
    using BorrowChecker: is_moved

    # Create owned value
    @bind x = 42
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == 42
        @test !is_moved(x)
    end

    # Create mutable owned value
    @bind @mut y = [1, 2, 3]
    @lifetime lt begin
        @ref ref = y in lt
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
        @ref ref = y in lt
        @test ref == [1, 2, 3]
        @test is_moved(x)
        @test !is_moved(y)
        @test_throws MovedError @ref d = x in lt
    end

    # Cannot move twice
    @test_throws MovedError @move z = x

    # Can move multiple times through chain
    @bind a = [1, 2, 3]
    @move @mut y = a  # Move to mutable
    @move z = y  # Move to immutable
    @lifetime lt begin
        @ref ref = z in lt
        @test ref == [1, 2, 3]
        @test is_moved(a) && is_moved(y) && !is_moved(z)
        @test_throws MovedError @ref d = a in lt
        @test_throws MovedError @ref d = y in lt
    end
end

@testitem "Primitive Types" begin
    # Primitives still follow move semantics for consistency
    @bind x = 42
    @move y = x
    @lifetime lt begin
        @ref ref = y in lt
        @test ref == 42
        @test_throws MovedError @ref d = x in lt
    end
end

@testitem "Immutable References" begin
    using BorrowChecker: is_moved

    @bind @mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == [1, 2, 3]  # Can read through reference
        @test !is_moved(x)  # Reference doesn't move ownership
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
    @bind p = Point(1, 2)
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
    @bind @mut mp = Point(1, 2)
    @lifetime lt begin
        @ref @mut mut_ref_p = mp in lt
        @test_throws "Cannot create mutable reference: value is already mutably borrowed" mut_ref_p.x ==
            1
        @test_throws ErrorException mut_ref_p.x = 10  # Can't modify immutable struct properties
    end
end

@testitem "Mutable Property Access" begin
    @bind @mut y = [1, 2, 3]
    @lifetime lt begin
        @ref @mut mut_ref = y in lt
        @test mut_ref == [1, 2, 3]  # Can read through reference
        push!(mut_ref, 4)  # Can modify through mutable reference

        @test_throws BorrowRuleError @ref d = y in lt
        @test_throws(
            "Cannot create immutable reference: value is mutably borrowed", @ref d = y in lt
        )
    end
end

@testitem "Referencing moved values" begin
    @bind z = [1, 2, 3]
    @move w = z
    @lifetime lt begin
        @test_throws MovedError @ref d = z in lt
        @test_throws BorrowRuleError @ref @mut d = z in lt
    end
end

@testitem "Function Ownership" begin
    using BorrowChecker: is_moved

    # Helper function that takes ownership
    function consume_vector(v::Vector{Int})
        push!(v, 4)
        return v
    end

    # Test taking ownership in function calls
    @bind @mut x = [1, 2, 3]
    @bind @mut result = consume_vector(@take x)
    @test result == [1, 2, 3, 4]
    @test is_moved(x)
    @lifetime lt begin
        @test_throws MovedError @ref d = x in lt
    end

    # Can't take ownership twice
    @test_throws MovedError consume_vector(@take x)

    # Test borrowing in function calls
    function borrow_vector(v)
        @test v == [1, 2, 3]
    end

    @bind y = [1, 2, 3]
    @lifetime lt begin
        @ref ref = y in lt  # Immutable borrow
        @test !is_moved(y)  # y is still valid
        @ref ref2 = y in lt
        @test ref2 == [1, 2, 3]
    end

    # Test mutable borrowing
    function modify_vector(v)
        return push!(v, 4)
    end

    @bind @mut z = [1, 2, 3]
    @lifetime lt begin
        @ref @mut ref = z in lt  # Mutable borrow
        push!(ref, 4)
        @test !is_moved(z)  # z is still valid
    end
    @lifetime lt begin
        @ref ref = z in lt
        @test ref == [1, 2, 3, 4]
    end
end

@testitem "Assignment Syntax" begin
    # Test normal assignment with @set on mutable
    @bind @mut x = [1, 2, 3]
    @set x = [4, 5, 6]
    @lifetime lt begin
        @ref ref = x in lt
        @test ref == [4, 5, 6]
    end

    # Test assignment to immutable fails
    @bind y = [1, 2, 3]
    @test_throws BorrowRuleError @set y = [4, 5, 6]

    # Test assignment after move
    @bind @mut z = [1, 2, 3]
    @move w = z
    @test_throws MovedError @set z = [4, 5, 6]

    # Test assignment with references
    @bind @mut v = [1, 2, 3]
    @lifetime lt begin
        @ref @mut ref = v in lt
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
    @bind x = [1, 2, 3]
    @lifetime lt begin
        @ref ref1 = x in lt
        @ref ref2 = x in lt
        @test ref1 == [1, 2, 3]
        @test ref2 == [1, 2, 3]
        @test x.immutable_borrows == 2

        # Can't create mutable reference while immutably borrowed
        @test_throws BorrowRuleError @ref @mut d = x in lt
    end
    @test x.immutable_borrows == 0  # All borrows cleaned up

    # Test mutable reference blocks
    @bind @mut y = [1, 2, 3]
    @bind @mut z = [4, 5, 6]
    @lifetime lt begin
        @ref @mut mut_ref1 = y in lt
        # Can't create another mutable reference to y
        @test_throws BorrowRuleError @ref @mut d = y in lt
        # Can't create immutable reference to y while mutably borrowed
        @test_throws BorrowRuleError @ref d = y in lt

        # But can create references to different variables
        @ref @mut mut_ref2 = z in lt
        push!(mut_ref1, 4)
        push!(mut_ref2, 7)
    end
    @test y.mutable_borrows == 0  # Borrows cleaned up
    @test z.mutable_borrows == 0
    @test y == [1, 2, 3, 4]  # Modifications persisted
    @test z == [4, 5, 6, 7]

    # Test mixing mutable and immutable references to different variables
    @bind @mut a = [1, 2, 3]
    @bind b = [4, 5, 6]
    @lifetime lt begin
        @ref @mut mut_ref = a in lt
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
    @bind @mut outer = [1, 2, 3]

    @lifetime lt let
        @ref @mut inner = outer in lt
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
    @bind x = [1, 2, 3]
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
    using BorrowChecker: is_moved

    # Test symbol tracking for owned values
    @bind x = 42
    @test x.symbol == :x

    @bind @mut y = [1, 2, 3]
    @test y.symbol == :y

    # Test symbol tracking through moves
    @move z = x
    # Gets new symbol when moved
    @test z.symbol == :z
    @test x.symbol == :x
    @test !is_moved(z)
    @test is_moved(x)

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
    @bind @mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        @test_throws BorrowRuleError x[1] = 5
    end
end

@testitem "Mutability changes through moves" begin
    using BorrowChecker: is_moved

    # Test moving from immutable to mutable
    @bind x = [1, 2, 3]
    @test_throws BorrowRuleError push!(x, 4)  # Can't modify immutable
    @move @mut y = x  # Move to mutable
    push!(y, 4)  # Can modify after move
    @test y == [1, 2, 3, 4]
    @test is_moved(x)

    # Test moving from mutable to immutable
    @bind @mut z = [1, 2, 3]
    push!(z, 4)  # Can modify mutable
    @move w = z  # Move to immutable
    @test_throws BorrowRuleError push!(w, 5)  # Can't modify after move to immutable
    @test is_moved(z)
    @test w == [1, 2, 3, 4]

    # Test chain of mutability changes
    @bind a = [1]
    @move @mut b = a  # immutable -> mutable
    push!(b, 2)
    @move c = b  # mutable -> immutable
    @test_throws BorrowRuleError push!(c, 3)
    @move @mut d = c  # immutable -> mutable
    push!(d, 3)
    @test d == [1, 2, 3]
    @test is_moved(a) && is_moved(b) && is_moved(c) && !is_moved(d)
end

@testitem "Math Operations" begin
    # Test binary operations with owned values
    @bind x = 2
    @bind @mut y = 3

    # Test owned op number
    @test x + 1 == 3
    @test y * 2 == 6

    # Test number op owned
    @test 1 + x == 3
    @test 2 * y == 6

    # Test owned op owned
    @test x + y == 5
    @test x * y == 6

    # Test unary operations
    @test -x == -2
    @test abs(x) == 2
    @test sin(y) == sin(3)

    # Test operations preserve ownership rules
    @move z = y
    @test_throws MovedError y + 1

    # Test operations through references
    @lifetime lt begin
        @ref rx = x in lt
        @ref rz = z in lt  # Changed to const reference

        # Test all combinations with references
        @test rx + 1 == 3  # ref op number
        @test 1 + rx == 3  # number op ref
        @test rx + rz == 5  # ref op ref
        @test -rx == -2    # unary op ref

        # Test we can't modify through immutable ref
        @test_throws BorrowRuleError @set rx = rx + 1
    end
end

@testitem "Thread race detection example" begin
    # From https://discourse.julialang.org/t/package-for-rust-like-borrow-checker-in-julia/124442/54

    # This isn't too good of a test, but we want to confirm
    # this syntax still works
    increment_counter!(ref::Ref) = (ref[] += 1)
    function bc_create_thread_race()
        # (Oops, I forgot to make this Atomic!)
        @bind @mut shared_counter = Ref(0)
        Threads.@threads for _ in 1:10000
            increment_counter!(@take shared_counter)
        end
    end
    @test_throws "Cannot use shared_counter: value has been moved" bc_create_thread_race()

    # This is the correct design, and thus won't throw
    function counter(thread_count::Integer)
        @bind @mut local_counter = 0
        for _ in 1:thread_count
            @set local_counter = local_counter + 1
        end
        @take local_counter
    end
    function bc_correct_counter()
        @bind num_threads = 4
        @bind total_count = 10000
        @bind count_per_thread = total_count ÷ num_threads
        @bind @mut tasks = Task[]
        for t_id in 1:num_threads
            @bind thread_count =
                count_per_thread + (t_id == 1) * (total_count % num_threads)
            @bind t = Threads.@spawn counter($(@take thread_count))
            push!(tasks, @take(t))
        end
        return sum(map(fetch, @take(tasks)))
    end

    @test bc_correct_counter() == 10000
end

@testitem "Thread safety" begin
    using BorrowChecker: BorrowRuleError

    @test Threads.nthreads() > 1

    # Create owned value in main thread
    @bind @mut x = [1, 2, 3]
    @test x[1] == 1

    # Try to access owned value directly in another thread (should fail)
    Threads.@threads :static for i in 1:5
        if Threads.threadid() != getfield(x, :threadid)
            @test_throws BorrowRuleError x[1]  # Test the exception type
        end
    end

    # Immutable references are fine though
    @lifetime lt begin
        @ref ref = x in lt
        Threads.@threads :static for i in 1:5
            @test ref[1] == 1
        end
    end
end

@testitem "Mutable references in threads" begin
    @bind @mut x = [1, 2, 3]
    @lifetime lt begin
        @ref @mut ref2 = x in lt
        Threads.@threads :static for i in 1:5
            if Threads.threadid() != getfield(x, :threadid)
                @test_throws BorrowRuleError ref2[1] == 1
            end
        end
    end
end

@testitem "Properly transfer ownership using @take" begin
    using BorrowChecker: is_moved

    @bind @mut x = [1, 2, 3]
    t = Threads.@spawn begin
        # Create new owned value in this thread
        @bind @mut y = @take(x)
        @test y == [1, 2, 3]

        # Can modify it since we own it in this thread
        push!(y, 4)
        @test y == [1, 2, 3, 4]

        @take(y)  # Return the value
    end
    result = fetch(t)
    @test result == [1, 2, 3, 4]
    @test is_moved(x)  # Original value was moved
end

@testitem "Symbol Checking" begin
    using BorrowChecker: is_moved

    # Test that symbol checking works for @take
    @bind @mut x = 42
    y = x  # This is illegal - should use @move
    @test_throws(
        "Variable `y` holds an object that was reassigned from `x`.\nRegular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership or `@set` to modify values.",
        @take y
    )

    # Test that symbol checking works for @move
    @bind @mut a = [1, 2, 3]
    b = a  # This is illegal - should use @move
    @test_throws(
        "Variable `b` holds an object that was reassigned from `a`.\nRegular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership or `@set` to modify values.",
        @move c = b
    )
end

@testitem "Iteration" begin
    @bind @mut x = [1, 2, 3]
    @lifetime lt begin
        @ref ref = x in lt
        for (i, xi) in enumerate(ref)
            @test xi isa Borrowed{Int}
            @test xi == x[i]
        end
    end
end
