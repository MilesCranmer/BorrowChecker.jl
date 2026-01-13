"""
    PerTaskCache{T,F}

A per-task cache that allows us to avoid repeated locking.
"""
struct PerTaskCache{T,F<:Function}
    constructor::F

    PerTaskCache{T}(constructor::F) where {T,F} = new{T,F}(constructor)
end
PerTaskCache{T}() where {T} = PerTaskCache{T}(() -> T())

function Base.getindex(cache::PerTaskCache{T}) where {T}
    tls = Base.task_local_storage()
    if haskey(tls, cache)
        return tls[cache]::T
    else
        value = cache.constructor()::T
        tls[cache] = value
        return value
    end
end

function Base.setindex!(cache::PerTaskCache{T}, value) where {T}
    tls = Base.task_local_storage()
    tls[cache] = convert(T, value)
    return value
end
