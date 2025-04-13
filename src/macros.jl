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
    AsMutable,
    OrLazy
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
See the `@lifetime` macro for more information on lifetime scopes.

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

# Examples

Say that we wish to safely modify an array by reference.
We have two owned variables, `ar1` and `ar2`,
and we wish to add the first element of `ar2` to `ar1`.

```
@own :mut ar1 = [1, 2]
@own ar2 = [3, 4]

add_first!(x, y) = (x[1] += y[1]; nothing)
```

If we set up a lifetime scope manually, we might write:

```julia
@lifetime lt begin
    @ref ~lt :mut ref1 = ar1
    @ref ~lt ref2 = ar2
    add_first!(ref1, ref2)
end
```

However, most of the time you only need to create a lifetime scope for a single function call,
so `@bc` lets us do this automatically:

```julia
@bc add_first!(@mut(ar1), ar2)
```

This will evaluate to something that is quite similar to the
manual lifetime scope.

`@bc` also supports non-owned variables, which will simply get passed through as-is.
"""
macro bc(call_expr)
    is_borrow_checker_enabled(__module__) || return esc(call_expr)
    return _bc(call_expr)
end

function _bc(call_expr)
    if !isexpr(call_expr, :call)
        error("Expression is not a function call")
    end

    # Extract function name and arguments
    func = call_expr.args[1]
    all_args = call_expr.args[2:end]

    lifetime_symbol = gensym("lifetime")
    ref_exprs = []
    pos_args = []
    kw_args = []

    # First pass: Separate positional and keyword arguments
    for arg in all_args
        if isexpr(arg, :parameters) || isexpr(arg, :kw)
            kw_exprs = isexpr(arg, :parameters) ? arg.args : [arg]
            # ^Deals with `f(a=1, b=2)` vs `f(; a=1, b=2)`
            for kw_ex in kw_exprs
                isexpr(kw_ex, :...) &&
                    error("Keyword splatting is not implemented yet in `@bc`")

                kw_pair, ref_expr = _process_keyword_arg(lifetime_symbol, kw_ex)
                push!(ref_exprs, ref_expr)
                push!(kw_args, kw_pair)
            end
        elseif isexpr(arg, :...)
            error("Positional splatting (`...`) is not implemented yet in `@bc`")
        else  # regular positional args
            pos_var = gensym("arg")
            push!(ref_exprs, _process_value(pos_var, lifetime_symbol, arg))
            push!(pos_args, pos_var)
        end
    end

    new_call = _construct_call(func, pos_args, kw_args)

    let_expr = quote
        let $lifetime_symbol = $(Lifetime)()
            try
                $(ref_exprs...)
                $new_call
            finally
                $(cleanup!)($lifetime_symbol)
            end
        end
    end

    return esc(let_expr)
end

function _process_value(out_sym, lt_sym, value)
    sym = QuoteNode(value isa Symbol ? value : :anonymous)
    return :($out_sym = $(maybe_ref)($lt_sym, $value, $sym))
end

function _process_keyword_arg(lt_sym, kw_ex)
    if kw_ex isa Symbol  # expressions like `f(; x)`
        keyword = kw_ex
        value = kw_ex
    else
        keyword, value = kw_ex.args
    end
    kw_var = gensym(string(keyword))
    ref_expr = _process_value(kw_var, lt_sym, value)
    return (keyword, kw_var), ref_expr
end

function _construct_call(func, pos_args, kw_args)
    isempty(kw_args) && return Expr(:call, func, pos_args...)
    param_block = Expr(:parameters, [Expr(:kw, k, v) for (k, v) in kw_args]...)
    return Expr(:call, func, param_block, pos_args...)
end

"""
    @mut expr

Marks a value to be borrowed mutably in a `@bc` macro call.
"""
macro mut(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return esc(:($(AsMutable)($expr)))
end

"""
    @cc closure_expr

"Closure Check" is a macro that attempts to verify a closure is compatible with the borrow checker.

Only immutable references (created with `@ref` and `@bc`) are allowed to be captured;
all other owned and borrowed variables that are captured will trigger an error.

# Examples

```julia
@own x = 1
@own :mut y = 2

@lifetime lt begin
    @ref ~lt z = x
    @ref ~lt :mut w = y
    
    # These error as the capturing breaks borrowing rules
    bad = @cc () -> x + 1
    bad2 = @cc () -> w + 1
    
    # However, you are allowed to capture immutable references
    good = @cc () -> z + 1
    # This will not error.
end
```
"""
macro cc(expr)
    is_borrow_checker_enabled(__module__) || return esc(expr)
    return esc(:($(_check_function_captures)($expr)))
end

function _check_function_captures(f::F) where {F}
    for i in 1:fieldcount(F)
        field_type = fieldtype(F, i)
        field_name = fieldname(F, i)
        if field_type <: Core.Box
            _assert_capture_allowed(typeof(getfield(f, i).contents), field_name)
        else
            _assert_capture_allowed(field_type, field_name)
        end
    end
    return f
end

function _assert_capture_allowed(::Type{T}, var_name::Symbol) where {T}
    if !_check_capture_allowed(T)
        error(
            "The closure function captured a variable `$var_name::$T`. " *
            "This is disallowed because variable captures of owned and mutable references " *
            "breaks the rules of the borrow checker. Only immutable references are allowed. " *
            "To fix this, you should use `@ref` to create an immutable reference to the " *
            "variable before capturing.",
        )
    end
end

# COV_EXCL_START
_check_capture_allowed(::Type) = true
_check_capture_allowed(::Type{<:OrLazy{Owned}}) = false
_check_capture_allowed(::Type{<:OrLazy{OwnedMut}}) = false
_check_capture_allowed(::Type{<:OrLazy{BorrowedMut}}) = false
# COV_EXCL_STOP

end
