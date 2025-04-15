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
        @ref ~m :mut arr = m[]
        @test arr == [1, 2, 3]
        push!(arr, 4)
    end

    # Verify the value was modified
    lock(m) do
        @ref ~m arr = m[]
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
            @ref ~m :mut dict = m[]
            dict[:counter] += 1
        end
    end

    # Verify the modification worked
    lock(m) do
        @ref ~m dict = m[]
        @test dict[:counter] == 10
    end
end

@testitem "Base.@lock syntax" begin
    using BorrowChecker
    using BorrowChecker.MutexModule: LockNotHeldError

    m = Mutex([1, 2, 3])

    Base.@lock m begin
        # Create an immutable reference
        @ref ~m arr_immut = m[]
        @test arr_immut == [1, 2, 3]

        # We shouldn't be able to modify the immutable reference
        @test_throws BorrowRuleError push!(arr_immut, 4)
    end

    Base.@lock m begin
        # Create a mutable reference
        @ref ~m :mut arr_mut = m[]
        push!(arr_mut, 4)
        @test arr_mut == [1, 2, 3, 4]
    end
end

@testitem "Mutex error messages" begin
    using BorrowChecker
    using BorrowChecker.MutexModule:
        LockNotHeldError, NoOwningMutexError, MutexGuardValueAccessError, MutexMismatchError

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

    # Test MutexMismatchError message
    m4 = Mutex([1, 2, 3])
    lock(m4)
    guard = m4[]
    m5 = Mutex([4, 5, 6])
    err = try
        # Create a ref that tries to mix different mutexes
        @ref ~m5 failed = guard
    catch e
        e
    end
    unlock(m4)
    @test err isa MutexMismatchError
    err_msg = sprint(io -> showerror(io, err))
    @test startswith(err_msg, "MutexMismatchError: ")
    @test occursin("must be the same", err_msg)
end
