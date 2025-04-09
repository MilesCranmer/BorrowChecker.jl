module MacrosModule

using MacroTools: @q, isexpr, splitarg, isdef

using ..TypesModule:
    Owned,
    OwnedMut,
    Borrowed,
    BorrowedMut,
    Lifetime,
    NoLifetime,
    AllWrappers,
    AllOwned,
    AllBorrowed,
    AsMutable
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
    cleanup!,
    maybe_ref
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

"""
    @bc func(args...; kwargs...)

Calls `func` with the given arguments and keyword arguments, automatically creating
temporary borrows for arguments that appear to be owned variables.
"""
macro bc(call_expr)
    is_borrow_checker_enabled(__module__) || return esc(call_expr)
    return _bc(call_expr)
end

"""
    @mut expr

Marks a value to be borrowed mutably in a `@bc` macro call.
"""
macro mut(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return esc(:($(AsMutable)($expr)))
end

# Process a value argument and generate the appropriate reference expression
function _process_value(lt_sym, value, sym_hint=nothing)
    if isexpr(value, :call) && value.args[1] == :mut
        # Mutable borrow
        arg = value.args[2]
        sym = if arg isa Symbol
            QuoteNode(arg)
        else
            (sym_hint !== nothing ? sym_hint : QuoteNode(:anonymous))
        end
        return :($(maybe_ref)($lt_sym, $(AsMutable)($arg), $sym))
    else
        # Regular immutable borrow
        sym = if value isa Symbol
            QuoteNode(value)
        else
            (sym_hint !== nothing ? sym_hint : QuoteNode(:anonymous))
        end
        return :($(maybe_ref)($lt_sym, $value, $sym))
    end
end

# Process a keyword argument
function _process_keyword_arg(lt_sym, keyword, value)
    kw_var = gensym(string(keyword))
    ref_expr = :($kw_var = $(_process_value(lt_sym, value)))
    return (keyword, kw_var), ref_expr
end

# Helper function for @bc implementation
function _bc(call_expr)
    if !isexpr(call_expr, :call)
        error("Expression is not a function call")
    end

    # Extract function name and arguments
    func = call_expr.args[1]
    args = call_expr.args[2:end]

    # Generate a unique symbol for the lifetime variable
    lt_sym = gensym("lt")

    # Create expressions for borrowing arguments and constructing the function call
    ref_exprs = []
    pos_args = []  # Store positional arguments

    # Store keyword arguments
    kw_args = []    # Store regular keywords
    has_kw_args = false

    # Process all arguments
    for arg in args
        if isexpr(arg, :parameters)
            # Process parameters block
            has_kw_args = true
            for kwarg in arg.args
                if isexpr(kwarg, :...) # Handle splatting in keyword parameters
                    error("Keyword splatting is not implemented yet")
                elseif isexpr(kwarg, :kw) && isexpr(kwarg.args[2], :...)
                    error("Keyword splatting is not implemented yet")
                else
                    # Regular keyword argument
                    keyword = kwarg.args[1]
                    value = kwarg.args[2]
                    kw_pair, ref_expr = _process_keyword_arg(lt_sym, keyword, value)
                    push!(ref_exprs, ref_expr)
                    push!(kw_args, kw_pair)
                end
            end
        elseif isexpr(arg, :kw)
            # Process individual keyword arguments
            has_kw_args = true
            keyword = arg.args[1]
            value = arg.args[2]

            if isexpr(value, :...)
                error("Keyword splatting is not implemented yet")
            else
                kw_pair, ref_expr = _process_keyword_arg(lt_sym, keyword, value)
                push!(ref_exprs, ref_expr)
                push!(kw_args, kw_pair)
            end
        else
            # Process positional arguments
            if isexpr(arg, :...)
                error("Positional splatting is not implemented yet")
            else
                pos_var = gensym("arg")
                push!(ref_exprs, :($pos_var = $(_process_value(lt_sym, arg))))
                push!(pos_args, pos_var)
            end
        end
    end

    # Construct the function call
    new_call = _construct_call(func, pos_args, kw_args, has_kw_args, ref_exprs)

    # Create a let block with a lifetime, process references, call the function, and clean up
    let_expr = quote
        let $lt_sym = $(Lifetime)()
            try
                $(ref_exprs...)
                $new_call
            finally
                $(cleanup!)($lt_sym)
            end
        end
    end

    return esc(let_expr)
end

# Construct the function call expression
function _construct_call(func, pos_args, kw_args, has_kw_args, ref_exprs)
    if !has_kw_args
        # No keyword arguments at all
        return Expr(:call, func, pos_args...)
    end

    # Has keyword arguments
    if isempty(kw_args)
        # No actual keyword args (just an empty parameters block)
        return Expr(:call, func, pos_args...)
    end

    # Use regular keyword args
    kw_pairs = [Expr(:kw, k, v) for (k, v) in kw_args]
    return Expr(:call, func, Expr(:parameters, kw_pairs...), pos_args...)
end

end
