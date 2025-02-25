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
    @own [:mut] x  # equivalent to @own [:mut] x = x
    @own [:mut] (x, y)  # equivalent to @own [:mut] (x, y) = (x, y)

Create a new owned variable. If `:mut` is specified, the value will be mutable.
Otherwise, the value will be immutable.

You may also use `@own` in a `for` loop to create an owned value for each iteration.
"""
macro own(expr::Union{Expr,Symbol})
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return _own(expr, false)
end

macro own(mut_flag::QuoteNode, expr::Union{Expr,Symbol})
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag != QuoteNode(:mut)
        error("First argument to @own must be :mut if two arguments are provided")
    end
    return _own(expr, true)
end

function _own(expr::Symbol, mut::Bool)
    return esc(:($(expr) = $(own)($(expr), :anonymous, $(QuoteNode(expr)), Val($mut))))
end

function _own(expr::Expr, mut::Bool)
    if Meta.isexpr(expr, :tuple)
        # Handle bare tuple case - convert to assignment
        names = expr.args
        return esc(
            quote
                ($(names...),) = $(own_for)(
                    ($(names...),), ($(map(QuoteNode, names)...),), Val($mut)
                )
                ($(names...),)
            end,
        )
    elseif Meta.isexpr(expr, :(=))
        # Handle assignment case
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
        loop_vars = expr.args[1]
        body = expr.args[2]

        # Get loop assignments - either from block or single assignment
        loop_assignments = if Meta.isexpr(loop_vars, :block)
            filter(x -> Meta.isexpr(x, :(=)), loop_vars.args)
        else
            # Single for loop case - treat as one assignment
            [loop_vars]
        end

        # Build nested for loops from inside out
        result = body
        for assignment in reverse(loop_assignments)
            loop_var = assignment.args[1]
            iter = assignment.args[2]

            result = Expr(
                :for,
                Expr(
                    :(=),
                    loop_var,
                    :($(own_for)($(iter), $(QuoteNode(loop_var)), Val($mut))),
                ),
                Expr(:block, result),
            )
        end

        return esc(result)
    else
        error("@own requires an assignment expression, tuple, symbol, or for loop")
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
    @lifetime a begin
        @ref ~a rx = x
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
    @ref ~lifetime [:mut] var = value
    @ref ~lifetime [:mut] (var1, var2, ...) = (value1, value2, ...)
    @ref ~lifetime [:mut] for var in iter
        # body
    end

Create a reference to an owned value within a lifetime scope.
If `:mut` is specified, creates a mutable reference.
Otherwise, creates an immutable reference.
Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.

!!! warning
    This will not detect aliasing in the iterator.
"""
macro ref(lifetime_expr::Expr, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return _ref(lifetime_expr, expr, false)
end

macro ref(lifetime_expr::Expr, mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    if mut_flag.value != :mut
        error("Second argument to @ref must be :mut")
    end
    return _ref(lifetime_expr, expr, true)
end

# Handle other argument types with appropriate error messages
macro ref(lifetime_expr::Symbol, expr::Expr)
    return error(
        "First argument to @ref must be a lifetime prefixed with ~, e.g. `@ref ~lt`"
    )
end

macro ref(mut_flag::QuoteNode, lifetime_expr::Any, expr::Expr)
    return error(
        "You should write `@ref ~lifetime :mut expr` instead of `@ref :mut ~lifetime expr`"
    )
end

function _ref(lifetime_expr::Expr, expr::Expr, mut::Bool)
    if !Meta.isexpr(lifetime_expr, :call) ||
        length(lifetime_expr.args) != 2 ||
        lifetime_expr.args[1] != :~
        error("First argument to @ref must be a lifetime prefixed with ~, e.g. `@ref ~lt`")
    end
    lifetime = lifetime_expr.args[2]
    if Meta.isexpr(expr, :(=))
        # Handle assignment case
        dest = expr.args[1]
        src = expr.args[2]
        if Meta.isexpr(dest, :tuple) && Meta.isexpr(src, :tuple)
            # Handle tuple unpacking
            if length(dest.args) != length(src.args)
                error("Number of variables must match number of values in tuple unpacking")
            end
            refs = []
            for (d, s) in zip(dest.args, src.args)
                push!(refs, :($d = $(ref)($lifetime, $s, $(QuoteNode(d)), Val($mut))))
            end
            return esc(
                quote
                    $(refs...)
                end,
            )
        elseif Meta.isexpr(dest, :tuple) ⊻ Meta.isexpr(src, :tuple)
            error("Cannot mix tuple and non-tuple arguments in @ref")
        else
            return esc(:($dest = $(ref)($lifetime, $src, $(QuoteNode(dest)), Val($mut))))
        end
    elseif Meta.isexpr(expr, :for)
        # Handle for loop case
        loop_var = expr.args[1].args[1]
        iter = expr.args[1].args[2]
        body = expr.args[2]
        return esc(
            quote
                for $loop_var in
                    $(ref_for)($lifetime, $iter, $(QuoteNode(loop_var)), Val($mut))
                    $body
                end
            end,
        )
    else
        error("@ref requires an assignment expression or for loop")
    end
end

"""
    @clone [:mut] new = old

Create a deep copy of a value, without moving the source.
If `:mut` is specified, the destination will be mutable.
Otherwise, the destination will be immutable.
"""
macro clone(expr::Expr)
    is_borrow_checker_enabled(__module__) ||
        return esc(:($(expr.args[1]) = $(maybe_deepcopy)($(expr.args[2]))))
    return _clone(expr, false)
end

macro clone(mut_flag::QuoteNode, expr::Expr)
    is_borrow_checker_enabled(__module__) ||
        return esc(:($(expr.args[1]) = $(maybe_deepcopy)($(expr.args[2]))))
    if mut_flag.value != :mut
        error("First argument to @clone must be :mut if two arguments are provided")
    end
    return _clone(expr, true)
end

function _clone(expr::Expr, mut::Bool)
    if !Meta.isexpr(expr, :(=))
        error("@clone requires an assignment expression")
    end
    dest = expr.args[1]
    src = expr.args[2]
    return esc(
        :($(dest) = $(clone)($(src), $(QuoteNode(src)), $(QuoteNode(dest)), Val($mut)))
    )
end

end
