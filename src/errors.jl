module ErrorsModule

abstract type BorrowError <: Exception end

struct MovedError <: BorrowError
    var::Symbol
end

struct BorrowRuleError <: BorrowError
    msg::String
end

struct SymbolMismatchError <: BorrowError
    expected::Symbol
    current::Symbol
end

function Base.showerror(io::IO, e::MovedError)
    return print(io, "Cannot use $(e.var): value has been moved")
end
function Base.showerror(io::IO, e::BorrowRuleError)
    return print(io, e.msg)
end
function Base.showerror(io::IO, e::SymbolMismatchError)
    return print(
        io,
        "Variable `$(e.current)` holds an object that was reassigned from `$(e.expected)`.\nRegular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership or `@set` to modify values.",
    )
end

end
