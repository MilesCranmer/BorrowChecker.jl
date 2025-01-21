module DisambiguationsModule

using ..TypesModule: AllWrappers, AllBorrowed, AllOwned, LazyAccessor
using ..SemanticsModule: request_value
using ..OverloadsModule: _maybe_read

# COV_EXCL_START
# --- Missing/WeakRef comparisons ---
for (T1, T2) in (
    (:AllWrappers, :Missing),
    (:Missing, :AllWrappers),
    (:AllWrappers, :WeakRef),
    (:WeakRef, :AllWrappers),
)
    @eval Base.:(==)(x::$(T1), y::$(T2)) = _maybe_read(x) == _maybe_read(y)
    if T1 != :WeakRef && T2 != :WeakRef
        @eval Base.isequal(x::$(T1), y::$(T2)) = isequal(_maybe_read(x), _maybe_read(y))
    end
end

# --- Range/Colon operations ---
function Base.:(:)(start::T, step::AllWrappers{<:Number}, stop::T) where {T<:Real}
    return start:(request_value(step, Val(:read))):stop
end
function Base.:(:)(start::A, step::AllWrappers{<:Number}, stop::C) where {A<:Real,C<:Real}
    return start:(request_value(step, Val(:read))):stop
end

# COV_EXCL_STOP
end
