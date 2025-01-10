module MacrosModule

using MacroTools
using MacroTools: rmlines

using ..TypesModule:
    Bound, BoundMut, Borrowed, BorrowedMut, Lifetime, NoLifetime, AllWrappers, AllBound
using ..SemanticsModule:
    request_value,
    mark_moved!,
    set_value!,
    validate_symbol,
    take,
    move,
    bind,
    bind_for,
    set,
    clone,
    ref,
    cleanup!
using ..PreferencesModule: is_borrow_checker_enabled

"""
    @bind x = value
    @bind :mut x = value
    @bind for var in iter
        # body
    end
    @bind :mut for var in iter
        # body
    end

Create a new owned value. If `:mut` is specified, the value will be mutable.
Otherwise, the value will be immutable.

For loops will create immutable owned values for each iteration by default.
If `:mut` is specified, each iteration will create mutable owned values.
"""
macro bind(expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        name = expr.args[1]
        value = expr.args[2]
        return esc(:($(name) = $(bind)($(value), $(QuoteNode(name)), Val(false))))
    elseif Meta.isexpr(expr, :for)
        # Handle for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in $(bind_for)($iter, $(QuoteNode(loop_var)), Val(false))
                    $body
                end
            end,
        )
    else
        error("@bind requires an assignment expression or for loop")
    end
end

macro bind(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @bind must be :mut if two arguments are provided")
    end
    if Meta.isexpr(expr, :(=))
        # Handle mutable assignment case
        name = expr.args[1]
        value = expr.args[2]
        return esc(:($(name) = $(bind)($(value), $(QuoteNode(name)), Val(true))))
    elseif Meta.isexpr(expr, :for)
        # Handle mutable for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in $(bind_for)($iter, $(QuoteNode(loop_var)), Val(true))
                    $body
                end
            end,
        )
    else
        error("@bind :mut requires an assignment expression or for loop")
    end
end

"""
    @move new = old
    @move :mut new = old

Transfer ownership from one variable to another, invalidating the old variable.
If `:mut` is not specified, the destination will be immutable.
Otherwise, the destination will be mutable.
For `isbits` types, this will automatically use `@clone` instead.
"""
macro move(expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        dest = expr.args[1]
        src = expr.args[2]
        return esc(
            :($(dest) = $(move)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(false)))
        )
    else
        error("@move requires an assignment expression")
    end
end

macro move(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @move must be :mut if two arguments are provided")
    end
    if !Meta.isexpr(expr, :(=))
        error("@move :mut requires an assignment expression")
    end
    dest = expr.args[1]
    src = expr.args[2]
    return esc(
        :($(dest) = $(move)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(true)))
    )
end

"""
    @take var

Take ownership of a value, typically used in function arguments.
Returns the inner value and marks the original as moved.
For `isbits` types, this will return a copy and not mark the original as moved.
"""
macro take(var)
    is_borrow_checker_enabled(__module__) || return esc(var)
    return esc(:($(take)($(var), $(QuoteNode(var)))))
end

"""
    @set x = value

Assign a value to the value of a mutable owned variable itself.
"""
macro set(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if !Meta.isexpr(expr, :(=))
        error("@set requires an assignment expression")
    end

    dest = expr.args[1]
    value = expr.args[2]

    return esc(:($(set)($(dest), $(QuoteNode(dest)), $(value))))
end

"""
    @lifetime name begin
        @ref rx = x in name
        @ref :mut ry = y in name
        # use refs here
    end

Create a lifetime scope for references. References created with this lifetime
are only valid within the block and are automatically cleaned up when the block exits.
Can be used with either begin/end blocks or let blocks.
"""
macro lifetime(name::Symbol, expr)
    if !(Meta.isexpr(expr, :block) || Meta.isexpr(expr, :let))
        error("@lifetime requires a block expression")
    end

    if !is_borrow_checker_enabled(__module__)
        return esc(
            quote
                let $(name) = $(NoLifetime)()
                    $expr
                end
            end,
        )
    end

    # Wrap the body in lifetime management
    return esc(
        quote
            let $(name) = $(Lifetime)()
                try
                    $expr
                finally
                    $(cleanup!)($(name))
                end
            end
        end,
    )
end

"""
    @ref var = value in lifetime
    @ref :mut var = value in lifetime

Create a reference to an owned value within the given lifetime scope.
If `:mut` is not specified, creates an immutable reference.
Otherwise, creates a mutable reference.
Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.
"""
macro ref(expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        if !Meta.isexpr(expr.args[2], :call) || expr.args[2].args[1] != :in
            error("@ref requires 'in' syntax: @ref var = value in lifetime")
        end
        dest = expr.args[1]
        src = expr.args[2].args[2]
        lifetime = expr.args[2].args[3]
        return esc(:($dest = $(ref)($lifetime, $src, $(QuoteNode(dest)), Val(false))))
    else
        error("@ref requires an assignment expression")
    end
end

macro ref(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @ref must be :mut if two arguments are provided")
    end
    if !Meta.isexpr(expr, :(=))
        error("@ref :mut requires an assignment expression")
    end
    if !Meta.isexpr(expr.args[2], :call) || expr.args[2].args[1] != :in
        error("@ref :mut requires 'in' syntax: @ref :mut var = value in lifetime")
    end
    dest = expr.args[1]
    src = expr.args[2].args[2]
    lifetime = expr.args[2].args[3]
    return esc(:($dest = $(ref)($lifetime, $src, $(QuoteNode(dest)), Val(true))))
end

"""
    @clone new = old
    @clone :mut new = old

Create a deep copy of a value, without moving the source.
If `:mut` is not specified, the destination will be immutable.
Otherwise, the destination will be mutable.
"""
macro clone(expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        dest = expr.args[1]
        src = expr.args[2]
        return esc(
            :($(dest) = $(clone)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(false)))
        )
    else
        error("@clone requires an assignment expression")
    end
end

macro clone(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @clone must be :mut if two arguments are provided")
    end
    if !Meta.isexpr(expr, :(=))
        error("@clone :mut requires an assignment expression")
    end
    dest = expr.args[1]
    src = expr.args[2]
    return esc(
        :($(dest) = $(clone)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(true)))
    )
end

end
