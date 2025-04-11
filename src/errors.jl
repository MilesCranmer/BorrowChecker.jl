module ErrorsModule

"""
    abstract type BorrowError <: Exception end

Base type for all errors related to borrow checking rules.
"""
abstract type BorrowError <: Exception end

"""
    MovedError <: BorrowError

Error thrown when attempting to use a value that has been moved.
"""
struct MovedError <: BorrowError
    var::Symbol
end

"""
    ExpiredError <: BorrowError

Error thrown when attempting to use a reference whose lifetime has expired.
"""
struct ExpiredError <: BorrowError
    var::Symbol
end

"""
    BorrowRuleError <: BorrowError

Error thrown when attempting to violate borrow checking rules, such as having multiple mutable references.
"""
struct BorrowRuleError <: BorrowError
    msg::String
end

"""
    SymbolMismatchError <: BorrowError

Error thrown when attempting to reassign a variable without using proper ownership transfer mechanisms.
"""
struct SymbolMismatchError <: BorrowError
    expected::Symbol
    current::Symbol
end

"""
    AliasedReturnError <: BorrowError

Error thrown when attempting to return a result with non-isbits element types,
which could lead to unintended aliasing with the original array.
"""
struct AliasedReturnError <: BorrowError
    operation::Function
    type::Type
    arg_count::Int
end

AliasedReturnError(operation::Function, type::Type) = AliasedReturnError(operation, type, 1)

function Base.showerror(io::IO, e::MovedError)
    var_str = e.var == :anonymous ? "value" : "`$(e.var)`"
    return print(io, "Cannot use $(var_str): value has been moved")
end

function Base.showerror(io::IO, e::ExpiredError)
    var_str = e.var == :anonymous ? "value" : "`$(e.var)`"
    return print(io, "Cannot use $(var_str): value's lifetime has expired")
end

function Base.showerror(io::IO, e::BorrowRuleError)
    return print(io, e.msg)
end

function Base.showerror(io::IO, e::SymbolMismatchError)
    current_str = e.current == :anonymous ? "Variable" : "Variable `$(e.current)`"
    expected_str = e.expected == :anonymous ? "another variable" : "`$(e.expected)`"

    return print(
        io,
        "$(current_str) holds an object that was reassigned from $(expected_str).\n" *
        "Regular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership.",
    )
end

function Base.showerror(io::IO, e::AliasedReturnError)
    return print(
        io,
        "Refusing to return result of $(e.operation), as the output of type `$(e.type)` contains mutable elements. " *
        "This can result in unintended aliasing with the original array, so " *
        "you must first call `@take!(...)` on each input argument when calling this function.",
    )
end

end
