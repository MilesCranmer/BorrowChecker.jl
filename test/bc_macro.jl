using TestItems
using BorrowChecker

@testitem "Basics" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows

    # Define test function
    function data_info(vec)
        # Verify that the input is a borrowed reference
        @test vec isa Borrowed
        return "Data length: $(length(vec))"
    end

    @own :mut my_vec = [1, 2, 3]

    # Check there are no borrows initially
    @test get_immutable_borrows(my_vec) == 0

    # Test immutable borrowing
    result = @bc data_info(my_vec)
    @test result == "Data length: 3"

    # Vector should be unchanged after immutable borrow
    @test @take(my_vec) == [1, 2, 3]

    # Check borrows are cleaned up after function call
    @test get_immutable_borrows(my_vec) == 0
end

@testitem "Mutable borrowing with @mut" begin
    using BorrowChecker
    using BorrowChecker: get_mutable_borrows, get_immutable_borrows

    # Define test function
    function modify_data!(vec)
        # Verify that the input is a mutable borrowed reference
        @test vec isa BorrowedMut
        push!(vec, 99)
        return "Modified data length: $(length(vec))"
    end

    @own :mut my_vec = [1, 2, 3]

    # Check there are no borrows initially
    @test get_mutable_borrows(my_vec) == 0

    # Test mutable borrowing
    result = @bc modify_data!(@mut(my_vec))
    @test result == "Modified data length: 4"

    # Vector should be modified after mutable borrow
    @test @take(my_vec) == [1, 2, 3, 99]

    # Check borrows are cleaned up after function call
    @test get_mutable_borrows(my_vec) == 0
end

@testitem "Mixed argument types" begin
    using BorrowChecker
    using BorrowChecker: get_mutable_borrows, get_immutable_borrows, get_owner

    @own :mut my_vec = [1, 2, 3]
    @own other_vec = [4, 5]

    @test get_mutable_borrows(my_vec) == 0
    @test get_immutable_borrows(other_vec) == 0

    # Define test function
    function mixed_args(mutable_arg, value_arg, immutable_arg)
        # Verify types of arguments
        @test mutable_arg isa BorrowedMut
        @test value_arg isa Int  # Primitive type passed as-is
        @test immutable_arg isa Borrowed
        @test get_mutable_borrows(my_vec) == 1
        @test get_immutable_borrows(other_vec) == 1

        push!(mutable_arg, 42)
        return "Processed all arguments"
    end

    # Test mix of arguments
    result = @bc mixed_args(@mut(my_vec), 123, other_vec)
    @test result == "Processed all arguments"

    # Mutable argument should be modified
    @test @take(my_vec) == [1, 2, 3, 42]

    # Immutable argument should be unchanged
    @test @take(other_vec) == [4, 5]

    # Check borrows are cleaned up after function call
    @test get_mutable_borrows(my_vec) == 0
    @test get_immutable_borrows(other_vec) == 0
end

@testitem "With keyword arguments" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows

    # Define test function
    function with_keywords(vec; name="default", optional=nothing)
        # Verify types of arguments
        @test vec isa Borrowed
        @test name isa String
        @test optional isa Borrowed

        if optional !== nothing
            @test optional isa Borrowed
        end

        return "Processed with keywords"
    end

    @own :mut my_vec = [1, 2, 3]
    @own other_vec = [4, 5]

    # Test with keyword arguments
    result = @bc with_keywords(my_vec; name="test", optional=other_vec)
    @test result == "Processed with keywords"

    #! format: off
    # Also works without semi-colon (different parsing required)
    result = @bc with_keywords(my_vec, name="test", optional=other_vec)
    #! format: on
end

@testitem "Using @take! to move ownership" begin
    using BorrowChecker
    using BorrowChecker: is_moved, get_mutable_borrows

    # Define test function
    function mixed_args(mutable_arg, value_arg, immutable_arg)
        # Verify types of arguments
        @test mutable_arg isa BorrowedMut
        @test value_arg isa Int
        @test immutable_arg isa Vector  # Should be raw value, not borrowed

        push!(mutable_arg, 42)
        return "Processed all arguments"
    end

    @own :mut my_vec = [1, 2, 3]
    @own :mut temp_vec = [10, 20, 30]

    # Test with @take!
    result = @bc mixed_args(@mut(my_vec), 456, @take!(temp_vec))
    @test result == "Processed all arguments"

    # Mutable argument should be modified
    @test @take(my_vec) == [1, 2, 3, 42]

    # temp_vec should be moved
    @test is_moved(temp_vec)
    @test_throws MovedError @take(temp_vec)
end

@testitem "Owning a result from @bc" begin
    using BorrowChecker

    # Define test function
    function data_info(vec)
        @test vec isa Borrowed
        return "Data length: $(length(vec))"
    end

    @own :mut my_vec = [1, 2, 3]

    @own owned_result = @bc data_info(my_vec)
    @test owned_result isa Owned
    @test owned_result == "Data length: 3"
end

@testitem "Borrow checking rules" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows, get_mutable_borrows

    # Define test functions
    function takes_immutable(x)
        @test x isa Borrowed
        return x
    end

    function takes_mutable(x)
        @test x isa BorrowedMut
        push!(x, 99)
        return x
    end

    function invalid_modification(x)
        @test x isa Borrowed
        # Try to modify through immutable reference - should fail
        @test_throws BorrowRuleError push!(x, 42)
        return x
    end

    @own :mut vec = [1, 2, 3]

    # Test immutable borrow
    @bc takes_immutable(vec)
    @test get_immutable_borrows(vec) == 0  # Should be cleaned up

    # Test mutable borrow
    @bc takes_mutable(@mut(vec))
    @test get_mutable_borrows(vec) == 0  # Should be cleaned up
    @test @take(vec) == [1, 2, 3, 99]  # Modification persisted

    # Test that trying to modify through immutable borrow fails
    @bc invalid_modification(vec)

    # Test that we can't have simultaneous mutable and immutable borrows
    @lifetime lt begin
        @ref ~lt ref = vec  # Create immutable reference
        @test_throws BorrowRuleError @bc takes_mutable(@mut(vec))
    end

    # Test that we can't have multiple mutable borrows
    @lifetime lt begin
        @ref ~lt :mut mref = vec  # Create mutable reference
        @test_throws BorrowRuleError @bc takes_mutable(@mut(vec))
    end
end

@testitem "Keyword arguments in parameters block" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows, get_mutable_borrows

    # Define test function with keyword arguments
    function test_params_block(x; a, b, c)
        @test x isa Borrowed
        @test a isa Borrowed
        @test @take(a) == [1, 2, 3]

        @test b isa BorrowedMut
        push!(b, 100)

        @test c isa Int

        return true
    end

    @own data = [10, 20, 30]
    @own vec_a = [1, 2, 3]
    @own :mut vec_b = [4, 5, 6]

    # Test with parameters block syntax
    result = @bc test_params_block(data; a=vec_a, b=@mut(vec_b), c=42)
    @test result

    # Should error if we try to pass a BorrowedMut:
    @test_throws BorrowRuleError @bc test_params_block(
        data; a=@mut(vec_a), b=@mut(vec_b), c=42
    )

    # Verify mutable reference worked
    @test @take(vec_b) == [4, 5, 6, 100]
end

@testitem "Error cases - splatting" begin
    using BorrowChecker
    using TestItems

    # Define test functions
    splat_pos(args...; kws...) = length(args) + length(kws)

    @own data = [1, 2, 3]

    # Test positional splatting error - must use eval to properly catch the error
    @test_throws LoadError @eval @bc splat_pos(data...)

    # Test keyword splatting error (via parameters)
    kw_splat = (a=1, b=2)
    @test_throws LoadError @eval @bc splat_pos(data; kw_splat...)
    @test_throws "Keyword splatting is not implemented yet" @eval @bc splat_pos(
        data; kw_splat...
    )
end

@testitem "Non-call expression error" begin
    using BorrowChecker

    # Test non-call expression
    @test_throws LoadError @eval @bc @own x = [1, 2]
    @test_throws "Expression is not a function call" @eval @bc begin end
end

@testitem "Using @bc with built-in function" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows

    # Standard library function
    @own data = [1, 2, 3, 4, 5]

    # Test with a built-in function with borrowed support
    @test @bc(sum(data)) == 15

    # Verify references are cleaned up
    @test get_immutable_borrows(data) == 0

    # Original data should still be usable
    @test @take(data) == [1, 2, 3, 4, 5]
end

@testitem "Borrowing with expression argument" begin
    using BorrowChecker
    using BorrowChecker: LazyAccessorOf, get_immutable_borrows, get_mutable_borrows

    mutable struct A
        a::Int
        b::Int
    end
    mutable struct B
        a::A
        c::Int
    end

    @own data = B(A(1, 2), 8)

    function f(x; check=true)
        @test x isa Borrowed
        check && @test get_immutable_borrows(data) == 1
        return x.a + x.b
    end

    @test data.a isa LazyAccessorOf{Owned}

    # We create refs _through_ the accessor
    result = @bc f(data.a)
    @test result == 3

    function g(; x, check=true)
        @test x isa Borrowed
        check && @test get_immutable_borrows(data) == 1
        return x.a + x.b
    end

    result = @bc g(; x=data.a)
    @test result == 3

    # This also works with mutable objects
    @own :mut data_mut = data
    @test data_mut.a isa LazyAccessorOf{OwnedMut}

    function f_mut(x; check=true)
        @test x isa BorrowedMut
        check && @test get_mutable_borrows(data_mut) == 1
        return x.a + x.b
    end
    function g_mut(; x)
        @test x isa BorrowedMut
        @test get_mutable_borrows(data_mut) == 1
        return x.a + x.b
    end

    result = @bc f(data_mut.a; check=false)
    @test result == 3

    result = @bc f_mut(@mut(data_mut.a))
    @test result == 3

    result = @bc g(; x=data_mut.a, check=false)
    @test result == 3

    result = @bc g_mut(; x=@mut(data_mut.a))
    @test result == 3
end

@testitem "Indexing" begin
    using BorrowChecker

    @own data = [[1], [2], [3]]
    f(x::Borrowed{<:Vector}) = @take(x[end])
    @test (@bc f(data[1:2])) == [2]
end

@testitem "Closures" begin
    using BorrowChecker

    @own data = [1, 2, 3]
    @test (@bc (x -> (@test x isa Borrowed; sum(x)))(data)) == 6
end

@testitem "Reborrowing" begin
    using BorrowChecker

    @own :mut data = [1, 2, 3]
    @lifetime lt begin
        @ref ~lt :mut ref = data
        # References are just passed through
        @test (@bc sum(ref)) == 6
    end
end

@testitem "Thread safety" begin
    using BorrowChecker

    @own :mut data = [1, 2, 3]

    channel_a = Channel(1)
    channel_b = Channel(1)
    function f(x)
        put!(channel_a, nothing)
        push!(x, 4)
        take!(channel_b)
    end

    task = @async @bc f(@mut(data))
    take!(channel_a)

    # Prevents us writing to it twice!
    @test_throws BorrowRuleError @bc f(@mut(data))

    put!(channel_b, nothing)
    wait(task)

    @test data == [1, 2, 3, 4]
end
