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

@testitem "Cannot own a mutex" begin
    using BorrowChecker
    using BorrowChecker.MutexModule: NoOwningMutexError

    m = Mutex([1, 2, 3])

    @test_throws NoOwningMutexError @own m_owned = m
    @test_throws NoOwningMutexError @own :mut m_owned_mut = m
end
