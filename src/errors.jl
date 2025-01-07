module ErrorsModule

abstract type BorrowError <: Exception end

struct MovedError <: BorrowError
    var::Symbol
end

struct BorrowRuleError <: BorrowError
    msg::String
end

function Base.showerror(io::IO, e::MovedError)
    return print(io, "Cannot use $(e.var): value has been moved")
end
Base.showerror(io::IO, e::BorrowRuleError) = print(io, e.msg)

end
