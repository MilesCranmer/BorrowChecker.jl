using TestItems
using BorrowChecker
using Base.Threads: @spawn, Condition, ReentrantLock

@testitem "Basic Mutex operations" begin
    using BorrowChecker
    using BorrowChecker.MutexModule: LockNotHeldError

    # Create a mutex with a vector
    m = Mutex([1, 2, 3])

    # Verify we can access the mutex's value inside a lock
    lock(m) do
        @ref_into :mut arr = m[]
        @test arr == [1, 2, 3]
        push!(arr, 4)
    end

    # Verify the value was modified
    lock(m) do
        @ref_into arr = m[]
        @test arr == [1, 2, 3, 4]
    end

    # Verify that we can't access the mutex outside a lock
    @test_throws LockNotHeldError m[]
end

@testitem "Mutex with borrow checker enabled" begin
    using BorrowChecker
    using BorrowChecker.MutexModule: LockNotHeldError

    # Create an owned value first, then move it into the mutex
    @own data_to_protect = Dict(:counter => 0)
    m = Mutex(@take!(data_to_protect))
    # Mutexes don't need to be `@own`ed! They are safe
    # to pass around as regular Julia objects.

    # Modify the value safely through the mutex
    Threads.@threads for _ in 1:10
        lock(m) do
            @ref_into :mut dict = m[]
            dict[:counter] += 1
        end
    end

    # Verify the modification worked
    lock(m) do
        @ref_into dict = m[]
        @test dict[:counter] == 10
    end
end

@testitem "Base.@lock syntax" begin
    using BorrowChecker
    using BorrowChecker.MutexModule: LockNotHeldError

    m = Mutex([1, 2, 3])

    Base.@lock m begin
        # Create an immutable reference
        @ref_into arr_immut = m[]
        @test arr_immut == [1, 2, 3]

        # We shouldn't be able to modify the immutable reference
        @test_throws BorrowRuleError push!(arr_immut, 4)
    end

    out = Base.@lock m begin
        # Create a mutable reference
        @ref_into :mut arr_mut = m[]
        push!(arr_mut, 4)
        @test arr_mut == [1, 2, 3, 4]
        arr_mut
    end
    @test_throws ExpiredError push!(out, 5)
    s = sprint(show, out)
    @test s == "[expired reference]"
end

@testitem "Mutex error messages" begin
    using BorrowChecker
    using BorrowChecker.MutexModule:
        LockNotHeldError, NoOwningMutexError, MutexGuardValueAccessError

    # Test LockNotHeldError message
    m1 = Mutex([1, 2, 3])
    err = try
        m1[]
    catch e
        e
    end
    @test err isa LockNotHeldError
    err_msg = sprint(io -> showerror(io, err))
    @test startswith(err_msg, "LockNotHeldError: ")
    @test occursin("Current task does not hold the lock", err_msg)

    # Test NoOwningMutexError message
    m2 = Mutex([1, 2, 3])
    err = try
        @own m_owned = m2
    catch e
        e
    end
    @test err isa NoOwningMutexError
    err_msg = sprint(io -> showerror(io, err))
    @test startswith(err_msg, "NoOwningMutexError: ")
    @test occursin("Cannot own a mutex", err_msg)

    # Test MutexGuardValueAccessError message
    m3 = Mutex([1, 2, 3])
    err = try
        m3.value  # Try to access a property directly
    catch e
        e
    end
    @test err isa MutexGuardValueAccessError
    err_msg = sprint(io -> showerror(io, err))
    @test startswith(err_msg, "MutexGuardValueAccessError: ")
    @test occursin("must be accessed through a reference", err_msg)
end

@testitem "Mutex show method" begin
    using BorrowChecker

    # Test showing a mutex with a simple value
    m1 = Mutex(42)
    output = sprint(show, m1)
    @test output == "Mutex{Int64}(42)"

    # Test showing a mutex with a more complex value
    m2 = Mutex([1, 2, 3])
    output = sprint(show, m2)
    @test output == "Mutex{Vector{Int64}}([1, 2, 3])"

    # Test showing a mutex with a composite type
    m3 = Mutex((a=1, b="test"))
    output = sprint(show, m3)
    @test occursin("NamedTuple", output)
    @test occursin("a = 1", output)
    @test occursin("b = \"test\"", output)

    # Test showing a locked mutex
    m4 = Mutex(42)
    try
        lock(m4)
        local output = sprint(show, m4)
        @test output == "Mutex{Int64}([locked])"
        @test trylock(m4) == false
        @test islocked(m4) == true
    finally
        unlock(m4)
    end
    @test islocked(m4) == false
    @test trylock(m4) == true
    unlock(m4)
end

@testitem "Disallowed Mutex creation" begin
    using BorrowChecker

    # Create an owned value
    @own owned_value = [1, 2, 3]

    # Test that creating a Mutex with a wrapper throws the expected error
    err = try
        Mutex(owned_value)
    catch e
        e
    end

    @test err isa ArgumentError
    err_msg = sprint(io -> showerror(io, err))
    @test occursin(
        "Cannot create a Mutex around an object of type `$(typeof(owned_value))`", err_msg
    )
end

@testitem "@ref_into error messages" begin
    using BorrowChecker
    using BorrowChecker.MacrosModule: _ref_into

    # Test error for invalid first argument to @ref_into
    err = try
        @eval @ref_into :invalid_mut x = y
    catch e
        e
    end
    err_msg = sprint(showerror, err)
    @test occursin("First argument to @ref_into must be :mut", err_msg)

    # Test error for non-assignment expression
    err = try
        @eval @ref_into x * 2
    catch e
        e
    end
    err_msg = sprint(showerror, err)
    @test occursin("@ref_into requires an assignment expression", err_msg)

    # Test error for non-assignment expression with :mut flag
    err = try
        @eval @ref_into :mut x * 2
    catch e
        e
    end
    err_msg = sprint(showerror, err)
    @test occursin("@ref_into requires an assignment expression", err_msg)
end
