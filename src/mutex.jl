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

struct LockNotHeldError <: Exception end
struct MutexGuardValueAccessError <: Exception end
struct MutexMismatchError <: Exception end
struct NoOwningMutexError <: Exception end

get_lock(m::AbstractMutex) = getfield(m, :lock)

unsafe_get_owner(m::AbstractMutex) = getfield(m, :value)

get_lifetime(m::AbstractMutex) = getfield(m, :lifetime)::Lifetime

function get_locked_by(m::AbstractMutex)
    isone(get_lock(m).owned) || throw(LockNotHeldError())
    return getfield(m, :locked_by)::Task
end

function Base.getproperty(::AbstractMutex, _::Symbol)
    throw(MutexGuardValueAccessError())
end

function Base.show(io::IO, m::AbstractMutex{T}) where {T}
    print(io, "Mutex{", T, "}(")
    value = request_value(unsafe_get_owner(m), Val(:read))
    show(io, value)
    return print(io, ")")
end

function Base.showerror(io::IO, ::LockNotHeldError)
    return print(
        io,
        "Current task does not hold the lock for this Mutex. Access via `m[]` is only allowed when the lock is held by the current task.",
    )
end
function Base.showerror(io::IO, ::MutexGuardValueAccessError)
    return print(
        io,
        "The value protected by a mutex must be accessed through a reference. Use `@ref ~m [:mut] ref_var = m[]` to create a reference.",
    )
end
function Base.showerror(io::IO, ::MutexMismatchError)
    return print(io, "Mutex mismatch: the lifetime mutex and guard mutex must be the same")
end
function Base.showerror(io::IO, ::NoOwningMutexError)
    return print(
        io,
        "Cannot own a mutex. Use regular Julia assignment syntax, like `m = Mutex([1, 2, 3])`.",
    )
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
    get_locked_by(m) !== current_task() && throw(LockNotHeldError())
    cleanup!(get_lifetime(m))
    m.lifetime = nothing
    m.locked_by = nothing
    Base.unlock(get_lock(m))
    return nothing
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
        if current_task() !== get_locked_by(mutex)
            throw(LockNotHeldError())
        end
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
    get_locked_by(mutex) !== current_task() && throw(LockNotHeldError())

    if mut
        return BorrowedMut(unsafe_get_owner(mutex), get_lifetime(mutex), dest_symbol)
    else
        return Borrowed(unsafe_get_owner(mutex), get_lifetime(mutex), dest_symbol)
    end
end

# Prevent ownership of mutexes
function own(::AbstractMutex, _, _::Symbol, ::Val{mut}) where {mut}
    throw(NoOwningMutexError())
end

end # module MutexModule
