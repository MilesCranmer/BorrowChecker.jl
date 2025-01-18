"""
    BorrowChecker.PreferencesModule

Module for managing BorrowChecker preferences, including enabling/disabling borrow checking per module.
"""
module PreferencesModule  # Largely borrowed from DispatchDoctor.jl

using Preferences: load_preference, has_preference, get_uuid

@enum IsCached::Bool begin
    Cached
    NotCached
end

struct Cache{A,B}
    cache::Dict{A,B}
    lock::Threads.SpinLock

    Cache{A,B}() where {A,B} = new{A,B}(Dict{A,B}(), Threads.SpinLock())  # COV_EXCL_LINE
end

const UUID_CACHE = Cache{UInt64,Base.UUID}()
const PREFERENCE_CACHE = Cache{Base.UUID,Tuple{Bool,IsCached}}()
const MODULE_CACHE = Cache{Module,Bool}()

function _cached_call(f::F, cache::Cache, key) where {F}
    lock(cache.lock) do
        get!(cache.cache, key) do
            f()
        end
    end
end

function _cached_get_uuid(m)
    _cached_call(UUID_CACHE, objectid(m)) do
        try
            get_uuid(m)
        catch
            Base.UUID(0)
        end
    end
end

function is_borrow_checker_enabled(calling_module)
    uuid = _cached_get_uuid(calling_module)
    (value, cached) = _cached_call(PREFERENCE_CACHE, uuid) do
        if has_preference(uuid, "borrow_checker")
            (load_preference(uuid, "borrow_checker"), Cached)
        else
            (true, NotCached)
        end
    end
    if cached == Cached
        return value
    else
        Base.@lock MODULE_CACHE.lock begin
            if haskey(MODULE_CACHE.cache, calling_module)
                return MODULE_CACHE.cache[calling_module]
            else
                MODULE_CACHE.cache[calling_module] = true
                return value
            end
        end
    end
end

function disable_borrow_checker!(m::Module)
    Base.@lock MODULE_CACHE.lock begin
        if haskey(MODULE_CACHE.cache, m) && MODULE_CACHE.cache[m]
            error(
                "BorrowChecker preferences were already cached for module $m. " *
                "Please call this function before any other BorrowChecker macros are used.",
            )
        end
        MODULE_CACHE.cache[m] = false
    end
    return nothing
end

end
