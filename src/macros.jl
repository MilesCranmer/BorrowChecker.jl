module MacrosModule

using MacroTools
using MacroTools: rmlines

using ..TypesModule:
    Owned, OwnedMut, Borrowed, BorrowedMut, Lifetime, NoLifetime, AllWrappers, AllOwned
using ..SemanticsModule:
    request_value,
    mark_moved!,
    validate_symbol,
    maybe_deepcopy,
    take,
    take!,
    move,
    own,
    own_for,
    set,
    clone,
    ref,
    ref_for,
    cleanup!
using ..PreferencesModule: is_borrow_checker_enabled

"""
    @own [:mut] x = value
    @own [:mut] x, y, z = (value1, value2, value3)
    @own [:mut] for var in iter
        # body
    end

Create a new owned variable. If `:mut` is specified, the value will be mutable.
Otherwise, the value will be immutable.

You may also use `@own` in a `for` loop to create an owned value for each iteration.
"""
macro own(expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return _own(expr, false)
end

macro own(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @own must be :mut if two arguments are provided")
    end
    return _own(expr, true)
end

function _own(expr::Expr, mut::Bool)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        lhs = expr.args[1]
        rhs = expr.args[2]
        if Meta.isexpr(lhs, :tuple) || Meta.isexpr(lhs, :parameters)
            # Handle tuple unpacking
            names = lhs.args
            return esc(
                quote
                    $(lhs) = $(own_for)($(rhs), ($(map(QuoteNode, names)...),), Val($mut))
                    $(lhs)
                end,
            )
        else
            # Regular single assignment
            name = expr.args[1]
            value = expr.args[2]
            return esc(
                :(
                    $(name) = $(own)(
                        $(value), $(QuoteNode(value)), $(QuoteNode(name)), Val($mut)
                    )
                ),
            )
        end
    elseif Meta.isexpr(expr, :for)
        # Handle for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in $(own_for)($(iter), $(QuoteNode(loop_var)), Val($mut))
                    $body
                end
            end,
        )
    else
        error("@own requires an assignment expression or for loop")
    end
end

"""
    @move [:mut] new = old

Transfer ownership from one variable to another, invalidating the old variable.
If `:mut` is specified, the destination will be mutable.
Otherwise, the destination will be immutable.
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
    @take! var

Take ownership of a value, typically used in function arguments.
Returns the inner value and marks the original as moved.
For `isbits` types, this will return a copy and not mark the original as moved.
"""
macro take!(var)
    is_borrow_checker_enabled(__module__) || return esc(var)
    return esc(:($(take!)($(var), $(QuoteNode(var)))))
end

"""
    @take var

Returns the inner value and does a deepcopy. This does _not_ mark the original as moved.
"""
macro take(var)
    if is_borrow_checker_enabled(__module__)
        return esc(:($(take)($(var), $(QuoteNode(var)))))
    else
        # Even when borrow checker is disabled, we still want to clone
        # the value to avoid mutating the original.
        return esc(:($(maybe_deepcopy)($(var))))
    end
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
# TODO: Doesn't this mess up closures? Like if I bind a variable to a closure,
#       then using `x = {value}` will actually be different than `x[] = {value}`.
#       But at the same time, binding variables to a closure is a bad idea. If there
#       was a way we could prevent that entirely, that would be nice.

"""
    @lifetime a begin
        @ref a rx = x
        # use refs here
    end

Create a lifetime scope for references. References created with this lifetime
are only valid within the block and are automatically cleaned up when the block exits.
"""
macro lifetime(name::Symbol, expr::Expr)
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
    @ref lifetime [:mut] var = value
    @ref lifetime [:mut] for var in iter
        # body
    end

Create a reference to an owned value within the given lifetime scope.
If `:mut` is specified, creates a mutable reference.
Otherwise, creates an immutable reference.
Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.

!!! warning
    This will not detect aliasing in the iterator.
"""
macro ref(lifetime::Symbol, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        dest = expr.args[1]
        src = expr.args[2]
        return esc(:($dest = $(ref)($lifetime, $src, $(QuoteNode(dest)), Val(false))))
    elseif Meta.isexpr(expr, :for)
        # Handle for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in
                    $(ref_for)($lifetime, $iter, $(QuoteNode(loop_var)), Val(false))
                    $body
                end
            end,
        )
    else
        error("@ref requires an assignment expression or for loop")
    end
end

macro ref(lifetime::Symbol, mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("Second argument to @ref must be :mut if three arguments are provided")
    end
    if Meta.isexpr(expr, :(=))
        # Handle assignment case
        dest = expr.args[1]
        src = expr.args[2]
        return esc(:($dest = $(ref)($lifetime, $src, $(QuoteNode(dest)), Val(true))))
    elseif Meta.isexpr(expr, :for)
        # Handle for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in
                    $(ref_for)($lifetime, $iter, $(QuoteNode(loop_var)), Val(true))
                    $body
                end
            end,
        )
    else
        error("@ref lifetime :mut requires an assignment expression or for loop")
    end
end

macro ref(mut_flag::QuoteNode, lifetime::Symbol, expr::Expr)
    return error(
        "You should write `@ref lifetime :mut expr` instead of `@ref :mut lifetime expr`"
    )
end

"""
    @clone [:mut] new = old

Create a deep copy of a value, without moving the source.
If `:mut` is specified, the destination will be mutable.
Otherwise, the destination will be immutable.
"""
macro clone(expr::Expr)
    if Meta.isexpr(expr, :(=))
        # Handle immutable case
        dest = expr.args[1]
        src = expr.args[2]
        if is_borrow_checker_enabled(__module__)
            return esc(
                :(
                    $(dest) = $(clone)(
                        $(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(false)
                    )
                ),
            )
        else
            # Even when borrow checker is disabled, we still want to clone
            # the value to avoid mutating the original.
            return esc(:($(dest) = $(maybe_deepcopy)($(src))))
        end
    else
        error("@clone requires an assignment expression")
    end
end

macro clone(mut_flag::QuoteNode, expr::Expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @clone must be :mut if two arguments are provided")
    end
    if !Meta.isexpr(expr, :(=))
        error("@clone :mut requires an assignment expression")
    end
    dest = expr.args[1]
    src = expr.args[2]
    if is_borrow_checker_enabled(__module__)
        return esc(
            :($(dest) = $(clone)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val(true)))
        )
    else
        # Even when borrow checker is disabled, we still want to clone
        # the value to avoid mutating the original.
        return esc(:($(dest) = $(maybe_deepcopy)($(src))))
    end
end

end
