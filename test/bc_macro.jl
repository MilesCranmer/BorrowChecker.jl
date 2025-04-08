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

@testitem "Splatting regular arguments" begin
    using BorrowChecker

    # Define test function
    function sum_all(args...)
        @test !(args[1] isa Borrowed)
        @test !(args[2] isa Borrowed)
        @test !(args[3] isa Borrowed)
        return sum(args)
    end
    nums = [1, 2, 3, 4, 5]
    @bc sum_all(1, 2, nums...)
end

@testitem "Taking values from owned collections for splatting" begin
    using BorrowChecker
    using BorrowChecker: is_moved

    # Define test function
    function verify_all(expected_type, args...)
        # Verify args are not borrowed (should be raw values)
        for arg in args
            @test arg isa expected_type
        end
        return sum(args)
    end

    @own x = 1
    @own y = 2
    @own :mut owned_nums = [6, 7, 8, 9, 10]
    @test @bc(verify_all(Int, @take(x), @take(y), @take(owned_nums)...)) == 43
    @test @bc(verify_all(Borrowed{Int}, x, y, owned_nums...)) == 43
    # TODO: Once we avoid borrowing on static, can set this to Int
end

@testitem "Modifying mutable args while using splats" begin
    using BorrowChecker
    using BorrowChecker: get_mutable_borrows, is_moved

    # Define test function
    function modify_and_sum(mutable_vec, args...)
        # Verify argument types
        @test mutable_vec isa BorrowedMut  # Should be mutable borrow
        for arg in args
            @test !(arg isa Borrowed)  # Args should be raw values
        end
        push!(mutable_vec, sum(args))
        return mutable_vec
    end

    @own :mut vec3 = [7, 8, 9]
    @own :mut vec1 = [1, 2, 3]

    # Check there are no borrows initially
    @test get_mutable_borrows(vec3) == 0
    @test !is_moved(vec1)

    # Should modify vec3 and add sum of splat arguments
    @bc modify_and_sum(@mut(vec3), @take(vec1)..., 42)

    # Check that vec3 was modified correctly
    @test @take(vec3) == [7, 8, 9, 48]  # 1+2+3+42 = 48

    # Check borrows are cleaned up
    @test get_mutable_borrows(vec3) == 0

    # Verify vec1 wasn't moved (since we used @take, not @take!)
    @test !is_moved(vec1)
end

@testitem "Moved values" begin
    using BorrowChecker
    using BorrowChecker: is_moved

    @own :mut temp_vec = [10, 20, 30]

    # Verify not moved initially
    @test !is_moved(temp_vec)

    # Take ownership by using @take!
    value = @take!(temp_vec)
    @test value == [10, 20, 30]

    # Verify it's moved now
    @test is_moved(temp_vec)

    # This should throw an error because temp_vec was moved
    @test_throws MovedError @take(temp_vec)
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
