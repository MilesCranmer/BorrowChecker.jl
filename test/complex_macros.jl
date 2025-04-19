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

    @own :mut data = [[1], [2], [3]]
    @lifetime lt begin
        @ref ~lt :mut ref = data

        f(x) = sum(x)

        # References are just passed through
        @test (@bc f(ref)) == [6]
        @test (@bc f(ref[1:2])) == [3]
        @test (@bc f(@mut(ref))) == [6]
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
        return take!(channel_b)
    end

    task = @async @bc f(@mut(data))
    take!(channel_a)

    # This call is guaranteed to run while the data is also
    # being accessed by the task, so it would normally cause a thread race!
    @test_throws BorrowRuleError @bc f(@mut(data))
    # This prevents us writing to it twice!

    put!(channel_b, nothing)
    wait(task)

    @test data == [1, 2, 3, 4]
end

@testitem "Error handling within called function" begin
    using BorrowChecker
    using BorrowChecker: get_mutable_borrows

    @own :mut my_vec = [10, 20]

    function throws_error_with_borrow!(vec)
        @test vec isa BorrowedMut
        @test get_mutable_borrows(my_vec) == 1
        push!(vec, 55)
        return error("Intentional error during execution")
    end

    @test get_mutable_borrows(my_vec) == 0

    # Call the function with @bc and expect an error
    # We use test_throws to ensure the correct error is propagated
    @test_throws "Intentional error during execution" @bc throws_error_with_borrow!(
        @mut(my_vec)
    )

    # IMPORTANT: Check that borrows are cleaned up even after the error
    @test get_mutable_borrows(my_vec) == 0

    # Verify that any partial modifications made before the error are still present
    @test @take(my_vec) == [10, 20, 55]
end

@testitem "With shorthand keyword arguments" begin
    using BorrowChecker
    using BorrowChecker: get_immutable_borrows

    # Define test function that uses shorthand keyword arguments
    function with_shorthand_keywords(; x, y, z=1)
        # Verify types of arguments
        @test x isa Borrowed
        @test y isa Borrowed
        @test z == 1

        return "Processed with shorthand keywords"
    end

    @own :mut x = [1, 2, 3]
    @own y = [4, 5]

    # Test with shorthand keyword arguments
    result = @bc with_shorthand_keywords(; x, y)
    @test result == "Processed with shorthand keywords"

    f(; x) = sum(x)

    @own x = [1, 2, 3]
    @own result = @bc f(; x)
    @test result == 6
end

@testitem "Static values are passed through" begin
    using BorrowChecker
    using BorrowChecker: is_static

    f(x) = (@test x isa Int; x)

    @own x = 1
    @test @bc(f(x)) == 1
end

@testitem "Closures with disallowed capture types" begin
    using BorrowChecker

    let
        # Owned variables cannot be captured
        @own x = 42
        @test_throws ErrorException @cc () -> x + 1

        # OwnedMut variables cannot be captured
        @own :mut y = 42
        @test_throws ErrorException @cc () -> y + 1

        # BorrowedMut variables cannot be captured
        @own :mut z = 42
        @lifetime lt begin
            @ref ~lt :mut mutref = z
            @test_throws ErrorException @cc () -> mutref + 1
        end

        # LazyAccessor of OwnedMut cannot be captured
        @own :mut a = (value=42,)
        @test_throws ErrorException @cc () -> a.value + 1
    end
end

@testitem "Closures with allowed capture types" begin
    using BorrowChecker

    let
        # Borrowed variables can be captured
        @own b = 42
        @lifetime lt begin
            @ref ~lt borrowed = b
            good = @cc () -> borrowed + 1
            @test good() == 43
        end

        # LazyAccessor of Borrowed can also be captured
        @own c = (value=42,)
        @lifetime lt begin
            @ref ~lt borrowed_struct = c
            good = @cc () -> borrowed_struct.value + 1
            @test good() == 43
        end

        # Regular variables can be captured
        regular = 42
        good = @cc () -> regular + 1
        @test good() == 43
    end
end

@testitem "Closures with multiple captures" begin
    using BorrowChecker

    let
        # Multiple valid captures
        @own b1 = 10
        @own b2 = 20
        regular = 5

        @lifetime lt begin
            @ref ~lt ref1 = b1
            @ref ~lt ref2 = b2

            # All safe captures
            good = @cc () -> ref1 + ref2 + regular
            @test good() == 35
        end

        # Mix of valid and invalid captures
        @own x = 10
        @lifetime lt begin
            @ref ~lt safe_ref = x

            # One invalid (owned) + one valid (borrowed) + one regular
            @test_throws ErrorException @cc () -> x + safe_ref + regular
        end

        # Multiple invalid captures
        @own :mut y = 20
        @own z = 30

        # Both owned variables, should fail
        @test_throws ErrorException @cc () -> y + z
    end
end

@testitem "Closures with input arguments" begin
    using BorrowChecker

    let
        # Valid capture with input argument
        @own x = 42
        @own alpha = 42
        @own beta = 42
        regular = 5

        @lifetime lt begin
            @ref ~lt borrowed = x

            # Closure with input argument and valid capture
            good = @cc input -> borrowed + input + regular
            @test good(3) == 50  # 42 + 3 + 5
            @test_throws ErrorException @cc input -> alpha + input + regular

            # Verifying we can also do keyword arguments
            good_kw = @cc bar(a; b=2) = borrowed + a + b + regular
            @test good_kw(3) == 52  # 42 + 3 + 2 + 5
            @test good_kw(3; b=10) == 60  # 42 + 3 + 10 + 5
        end
        @test_throws ErrorException @cc foo(a::Int, b=2) = beta + a + b + regular

        # Invalid capture with input argument
        @own y = 100

        # The owned variable is still not allowed to be captured
        # even with input arguments present
        @test_throws ErrorException @cc (input,) -> y + input
    end
end

@testitem "Closures with multiple arguments" begin
    using BorrowChecker

    let
        # Test with multiple arguments including mutable references
        @own :mut a = [1, 2]
        @own b = 5
        @own :mut c = [10, 20]
        regular = 100

        @lifetime lt begin
            @ref ~lt :mut mut_a = a
            @ref ~lt borrowed_b = b
            @ref ~lt :mut mut_c = c

            # Closure with multiple arguments of different types
            process = @cc (x_mut, y, z_mut) -> begin
                push!(x_mut, y + 1)
                push!(z_mut, y * 2)
                return borrowed_b + regular
            end

            # Call with multiple arguments
            result = process(mut_a, 3, mut_c)
            @test result == 105  # borrowed_b (5) + regular (100)

            # Call again with different parameters
            result = process(mut_c, 7, mut_a)
            @test result == 105
        end

        # Now check the results AFTER the lifetime has ended and borrows are released
        @test @take(a) == [1, 2, 4, 14]  # Added 3+1 and 7*2
        @test @take(c) == [10, 20, 6, 8]  # Added 3*2 and 7+1
    end
end
@testitem "Closure with arg name matching a captured name" begin
    using BorrowChecker

    let
        @own x = 42
        f = @cc x -> x + 1
        @test f(1) == 2

        @lifetime lt begin
            @ref ~lt r = x
            g = @cc foo(a; x) = a + x + r
            @test g(1; x=2) == 1 + 2 + 42
        end
    end
end

@testitem "Nested closures" begin
    using BorrowChecker
    using DispatchDoctor: allow_unstable

    let
        @own complex_data = Dict("a" => 10, "b" => 20)
        @own :mut results = []
        counter = 0

        @lifetime lt begin
            @ref ~lt data_ref = complex_data

            closure_factory = @cc (prefix) -> begin
                local captured_counter = counter
                counter += 1  # Modify the outer variable
                # ^This is bad, but should not trigger an error!

                # Return a new closure that captures allowed references
                # and accepts a mutable reference as an argument (not captured)
                return @cc (x, mut_results) -> begin
                    # Access the borrowed dictionary
                    value = data_ref[prefix] * x
                    # Use the mutable reference as an argument
                    push!(mut_results, "$(prefix): $value (#$(captured_counter))")
                    return value
                end
            end

            @ref ~lt :mut results_mut = results

            @test closure_factory("a")(5, results_mut) == 50  # 10 * 5
            @test closure_factory("b")(3, results_mut) == 60  # 20 * 3

            # Check the results within the lifetime scope
            @test length(results_mut) == 2
            allow_unstable() do
                @test results_mut[1] == "a: 50 (#0)"
                @test results_mut[2] == "b: 60 (#1)"
            end
        end

        @test @take(results) == ["a: 50 (#0)", "b: 60 (#1)"]
    end
end

@testitem "Boxed owned variables" begin
    using BorrowChecker

    let
        @own :mut x = 42
        f = () -> begin
            local y = x
            x += 1
        end
        # First, we verify that this created a boxed variable
        @test f.x isa Core.Box
        # TODO: Change when https://github.com/JuliaLang/julia/issues/15276 is fixed

        # Then, we verify we can detect the underlying variable within the box
        @test_throws(
            "The closure function captured a variable `x::$(typeof(x))`",
            @cc () -> begin
                local y = x
                x += 1
            end
        )
    end
end

@testitem "Simple @spawn macro" begin
    using BorrowChecker
    using BorrowChecker: @spawn

    @test_throws "The closure function captured a variable `x" let
        @own x = 1
        fetch(@spawn x + 1)
    end
    @test_throws "The closure function captured" let
        @own :mut x = 1
        fetch(@spawn x + 1)
    end
    @test_throws "The closure function captured" let
        @own :mut x = 1
        @lifetime lt begin
            @ref ~lt :mut borrowed = x
            fetch(@spawn borrowed + 1)
        end
    end
    let
        @own :mut x = 1
        @lifetime lt begin
            @ref ~lt borrowed = x
            @test fetch(@spawn borrowed + 1) == 2
        end
    end
end

@testitem "Valid uses of @spawn macro" begin
    using BorrowChecker
    using BorrowChecker: @spawn

    let
        @own x = [1, 2, 3]
        ch = Channel(1)
        t = @lifetime lt begin
            @ref ~lt borrowed = x
            @test fetch(@spawn borrowed .+ 1) == [2, 3, 4]

            # We want to verify that the borrow expires in this spawn:
            @spawn (take!(ch); borrowed .+ 1)
        end
        put!(ch, 1)
        err_msg = try
            fetch(t)
        catch e
            sprint(showerror, e)
        end
        @test occursin("Cannot use `borrowed`: value's lifetime has expired", err_msg)
    end
end
