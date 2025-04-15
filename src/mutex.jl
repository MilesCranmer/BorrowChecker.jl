module MutexModule

using ..ErrorsModule: BorrowRuleError
using ..TypesModule: OwnedMut, Lifetime, Borrowed, BorrowedMut
using ..SemanticsModule: request_value, validate_mode, cleanup!

import ..SemanticsModule: ref, own

"""
    AbstractMutex{T}

Abstract type for mutex implementations that protect a value of type T.
"""
abstract type AbstractMutex{T} <: Base.AbstractLock end

"""
    Mutex{T} <: AbstractMutex{T}

A mutex that protects a value of type T.
Provides safe concurrent access to the protected value.

# Example
```julia
m = Mutex([1, 2, 3])
lock(m)
@ref ~m :mut arr = m[]
push!(arr, 4)
unlock(m)
```
"""
mutable struct Mutex{T} <: AbstractMutex{T}
    const value::OwnedMut{T}
    const lock::Threads.SpinLock
    locked_by::Union{Task,Nothing}
    lifetime::Union{Lifetime,Nothing}

    function Mutex(value::T) where {T}
        owned_value = own(value, :anonymous, :anonymous, Val(true))
        return new{T}(owned_value, Threads.SpinLock(), nothing, nothing)
    end
end

get_lock(m::AbstractMutex) = getfield(m, :lock)

unsafe_get_owner(m::AbstractMutex) = getfield(m, :value)

get_lifetime(m::AbstractMutex) = getfield(m, :lifetime)::Lifetime

abstract type AbstractMutexError <: Exception end

struct LockNotHeldError <: AbstractMutexError end

function _verify_task(m::AbstractMutex)
    isone(get_lock(m).owned) || throw(LockNotHeldError())
    getfield(m, :locked_by) === current_task() || throw(LockNotHeldError())
    return nothing
end

function Base.showerror(io::IO, ::LockNotHeldError)
    print(io, "LockNotHeldError: ")
    print(io, "Current task does not hold the lock for this Mutex. ")
    print(io, "Access via `m[]` is only allowed when the lock is held by the current task.")
    return nothing
end

struct MutexGuardValueAccessError <: AbstractMutexError end

function Base.getproperty(::AbstractMutex, _::Symbol)
    throw(MutexGuardValueAccessError())
end

function Base.showerror(io::IO, ::MutexGuardValueAccessError)
    print(io, "MutexGuardValueAccessError: ")
    print(io, "The mutex value must be accessed through a reference. ")
    print(io, "For example, `@ref ~m [:mut] ref_var = m[]`.")
    return nothing
end

function Base.show(io::IO, m::AbstractMutex{T}) where {T}
    if trylock(m)
        try
            print(io, "Mutex{", T, "}(")
            value = request_value(unsafe_get_owner(m), Val(:read))
            show(io, value)
            print(io, ")")
        finally
            unlock(m)
        end
    else
        print(io, "Mutex{", T, "}([locked])")
    end
    return nothing
end

"""
    lock(m::AbstractMutex)

Lock the mutex, creating a lifetime to allow for references to the protected value.
"""
function Base.lock(m::AbstractMutex)
    Base.lock(get_lock(m))
    m.locked_by = current_task()
    m.lifetime = Lifetime()
    return m
end

"""
    unlock(m::AbstractMutex)

Unlock the mutex, cleaning up all references created during this lock session.
"""
function Base.unlock(m::AbstractMutex)
    _verify_task(m)
    cleanup!(get_lifetime(m))
    m.lifetime = nothing
    m.locked_by = nothing
    Base.unlock(get_lock(m))
    return nothing
end

function Base.trylock(m::AbstractMutex)
    if Base.trylock(get_lock(m))
        m.locked_by = current_task()
        m.lifetime = Lifetime()
        return true
    else
        return false
    end
end

function Base.islocked(m::AbstractMutex)
    return Base.islocked(get_lock(m))
end

"""
    MutexGuard{T,M<:AbstractMutex{T}}

A guard object that represents a locked mutex. 
Created automatically when accessing a mutex's value with `m[]`.
Use `@ref ~lt [:mut] ref_var = mutex_guard` to obtain a reference to the guarded value.
"""
struct MutexGuard{T,M<:AbstractMutex{T}}
    mutex::M

    function MutexGuard(mutex::M) where {T,M<:AbstractMutex{T}}
        _verify_task(mutex)
        return new{T,M}(mutex)
    end
end

"""
    getindex(m::AbstractMutex)

Access the mutex for referencing. Must be used inside a lock block and with @ref.
Throws a `LockNotHeldError` if the current task does not hold the lock.
"""
Base.getindex(m::AbstractMutex) = MutexGuard(m)
# TODO: This MutexGuard shouldn't be passed when BorrowChecker is disabled

# Overload ref for MutexGuard to create proper references
function ref(
    mutex::AbstractMutex, guard::MutexGuard, dest_symbol::Symbol, ::Val{mut}
) where {mut}
    mutex !== guard.mutex && throw(MutexMismatchError())
    _verify_task(mutex)

    if mut
        return BorrowedMut(unsafe_get_owner(mutex), get_lifetime(mutex), dest_symbol)
    else
        return Borrowed(unsafe_get_owner(mutex), get_lifetime(mutex), dest_symbol)
    end
end

struct MutexMismatchError <: AbstractMutexError end

function Base.showerror(io::IO, ::MutexMismatchError)
    print(io, "MutexMismatchError: ")
    print(io, "The lifetime mutex and guard mutex must be the same.")
    return nothing
end

# Prevent ownership of mutexes
function own(::AbstractMutex, _, _::Symbol, ::Val{mut}) where {mut}
    throw(NoOwningMutexError())
end

struct NoOwningMutexError <: AbstractMutexError end

function Base.showerror(io::IO, ::NoOwningMutexError)
    print(io, "NoOwningMutexError: ")
    print(io, "Cannot own a mutex. Use regular Julia assignment syntax, ")
    print(io, "like `m = Mutex([1, 2, 3])`.")
    return nothing
end

end # module MutexModule
