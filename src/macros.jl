module MacrosModule

using MacroTools
using MacroTools: rmlines

using ..TypesModule: Owned, OwnedMut, Borrowed, BorrowedMut, Lifetime, AllWrappers, AllOwned
using ..SemanticsModule: request_value, mark_moved!, set_value!, validate_symbol

"""
    @bind x = value
    @bind @mut x = value

Create a new owned value. If `@mut` is specified, the value will be mutable.
Otherwise, the value will be immutable.
"""
macro bind(expr)
    if Meta.isexpr(expr, :macrocall) && expr.args[1] == Symbol("@mut")
        # Handle mutable case
        if !Meta.isexpr(expr.args[3], :(=))
            error("@bind @mut requires an assignment expression")
        end
        name = expr.args[3].args[1]
        value = expr.args[3].args[2]
        return esc(:($(name) = $(OwnedMut)($(value), false, $(QuoteNode(name)))))
    elseif Meta.isexpr(expr, :(=))
        # Handle immutable case
        name = expr.args[1]
        value = expr.args[2]
        return esc(:($(name) = $(Owned)($(value), false, $(QuoteNode(name)))))
    else
        error("@bind requires an assignment expression")
    end
end

"""
    @move new = old
    @move @mut new = old

Transfer ownership from one variable to another, invalidating the old variable.
If `@mut` is not specified, the destination will be immutable.
Otherwise, the destination will be mutable.
"""
macro move(expr)
    if Meta.isexpr(expr, :macrocall) && expr.args[1] == Symbol("@mut")
        # Handle mutable case
        if !Meta.isexpr(expr.args[3], :(=))
            error("@move @mut requires an assignment expression")
        end
        dest = expr.args[3].args[1]
        src = expr.args[3].args[2]
        value = gensym(:value)

        return esc(
            quote
                $(validate_symbol)($src, $(QuoteNode(src)))
                $value = $(request_value)($src, Val(:move))
                $dest = $(OwnedMut)($value, false, $(QuoteNode(dest)))
                $(mark_moved!)($src)
                $dest
            end,
        )
    elseif Meta.isexpr(expr, :(=))
        # Handle immutable case
        dest = expr.args[1]
        src = expr.args[2]
        value = gensym(:value)

        return esc(
            quote
                $(validate_symbol)($src, $(QuoteNode(src)))
                $value = $(request_value)($src, Val(:move))
                $dest = $(Owned)($value, false, $(QuoteNode(dest)))
                $(mark_moved!)($src)
                $dest
            end,
        )
    else
        error("@move requires an assignment expression")
    end
end

"""
    @take var

Take ownership of a value, typically used in function arguments.
Returns the inner value and marks the original as moved.
"""
macro take(var)
    value = gensym(:value)
    return esc(
        quote
            $(validate_symbol)($var, $(QuoteNode(var)))
            $value = $(request_value)($var, Val(:move))
            $(mark_moved!)($var)
            $value
        end,
    )
end

"""
    @set x = value

Assign a value to the value of a mutable owned variable itself.
"""
macro set(expr)
    if !Meta.isexpr(expr, :(=))
        error("@set requires an assignment expression")
    end

    dest = expr.args[1]
    value = expr.args[2]

    return esc(:($(set_value!)($dest, $value)))
end

function cleanup!(lifetime::Lifetime)
    # Clean up immutable references
    for owner in lifetime.immutable_refs
        owner.immutable_borrows -= 1
    end
    empty!(lifetime.immutable_refs)

    # Clean up mutable references
    for owner in lifetime.mutable_refs
        owner.mutable_borrows -= 1
    end
    return empty!(lifetime.mutable_refs)
end

"""
    @lifetime name begin
        @ref name(rx = x)
        @ref_mut name(ry = y)
        # use refs here
    end

Create a lifetime scope for references. References created with this lifetime
are only valid within the block and are automatically cleaned up when the block exits.
Can be used with either begin/end blocks or let blocks.
"""
macro lifetime(name, body)
    if !Meta.isexpr(body, :block) && !Meta.isexpr(body, :let)
        error("@lifetime requires a begin/end block or let block")
    end

    inner_body = if Meta.isexpr(body, :let)
        let_expr = body.args[1]
        let_body = body.args[2]
        if isempty(rmlines(let_expr).args)
            quote
                let
                    $let_body
                end
            end
        else
            quote
                let $let_expr
                    $let_body
                end
            end
        end
    else
        body
    end

    # Wrap the body in lifetime management
    return esc(
        quote
            let $(name) = $(Lifetime)()
                try
                    $inner_body
                finally
                    $(cleanup!)($(name))
                end
            end
        end,
    )
end

"""
    @ref var = value in lifetime
    @ref @mut var = value in lifetime

Create a reference to an owned value within the given lifetime scope.
If `@mut` is not specified, creates an immutable reference.
Otherwise, creates a mutable reference.
Returns a Borrowed{T} or BorrowedMut{T} that forwards access to the underlying value.
"""
macro ref(expr)
    if Meta.isexpr(expr, :macrocall) && expr.args[1] == Symbol("@mut")
        # Handle mutable case
        if !Meta.isexpr(expr.args[3], :(=))
            error("@ref @mut requires an assignment expression")
        end
        dest = expr.args[3].args[1]
        if !Meta.isexpr(expr.args[3].args[2], :call) || expr.args[3].args[2].args[1] != :in
            error("@ref @mut requires 'in' syntax: @ref @mut var = value in lifetime")
        end
        src = expr.args[3].args[2].args[2]
        lifetime = expr.args[3].args[2].args[3]
        return esc(:($dest = $(BorrowedMut)($src, $lifetime)))
    elseif Meta.isexpr(expr, :(=))
        # Handle immutable case
        if !Meta.isexpr(expr.args[2], :call) || expr.args[2].args[1] != :in
            error("@ref requires 'in' syntax: @ref var = value in lifetime")
        end
        dest = expr.args[1]
        src = expr.args[2].args[2]
        lifetime = expr.args[2].args[3]
        return esc(:($dest = $(create_immutable_ref)($lifetime, $src)))
    else
        error("@ref requires an assignment expression")
    end
end

function create_immutable_ref(lt::Lifetime, ref_or_owner::AllWrappers)
    # TODO: Put this in `Borrowed`

    is_owner = ref_or_owner isa AllOwned
    owner = is_owner ? ref_or_owner : ref_or_owner.owner

    if !is_owner
        @assert(
            ref_or_owner.lifetime === lt,
            "Lifetime mismatch! Nesting lifetimes is not allowed."
        )
    end

    if is_owner
        return Borrowed(owner, lt)
    else
        return Borrowed(request_value(ref_or_owner, Val(:read)), owner, lt)
    end
end

end
