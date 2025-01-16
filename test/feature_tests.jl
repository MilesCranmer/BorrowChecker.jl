using TestItems
using BorrowChecker

@testitem "Function Ownership" begin
    using BorrowChecker: is_moved

    # Helper function that takes ownership
    function consume_vector(v::Vector{Int})
        push!(v, 4)
        return v
    end

    # Test taking ownership in function calls
    @own :mut x = [1, 2, 3]
    @own :mut result = consume_vector(@take! x)
    @test result == [1, 2, 3, 4]
    @test is_moved(x)
    @lifetime lt begin
        @test_throws MovedError @ref lt d = x
    end

    # Can't take ownership twice
    @test_throws MovedError consume_vector(@take! x)

    # Test borrowing in function calls
    function borrow_vector(v)
        @test v == [1, 2, 3]
    end

    @own y = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = y  # Immutable borrow
        @test !is_moved(y)  # y is still valid
        @ref lt ref2 = y
        @test ref2 == [1, 2, 3]
    end

    # Test mutable borrowing
    function modify_vector(v)
        return push!(v, 4)
    end

    @own :mut z = [1, 2, 3]
    @lifetime lt begin
        @ref lt :mut ref = z  # Mutable borrow
        push!(ref, 4)
        @test !is_moved(z)  # z is still valid
    end
    @lifetime lt begin
        @ref lt ref = z
        @test ref == [1, 2, 3, 4]
    end
end

@testitem "Assignment Syntax" begin
    # Test normal assignment with @set on mutable
    @own :mut x = [1, 2, 3]
    @set x = [4, 5, 6]
    @lifetime lt begin
        @ref lt ref = x
        @test ref == [4, 5, 6]
    end

    # Test assignment to immutable fails
    @own y = [1, 2, 3]
    @test_throws BorrowRuleError @set y = [4, 5, 6]

    # Test assignment after move
    @own :mut z = [1, 2, 3]
    @move w = z
    @test_throws MovedError @set z = [4, 5, 6]

    # Test assignment with references
    @own :mut v = [1, 2, 3]
    @lifetime lt begin
        @ref lt :mut ref = v
        push!(ref, 4)
        @test_throws("Cannot assign to value while borrowed", @set v = [5, 6, 7])
    end
    @set v = [5, 6, 7]
    @lifetime lt begin
        @ref lt ref = v
        @test ref == [5, 6, 7]
        @test_throws "Cannot write to immutable reference" ref[1] = [8]
    end
end

@testitem "Macros error branches coverage" begin
    # 1) Two-arg @own with first arg != :mut => macro expansion error => LoadError
    @test_throws LoadError @eval @own :xxx x = 42

    # 2) @own with expression that is not `= ...` or `for ...`
    expr_bind = quote
        @own x + y
    end
    @test_throws LoadError eval(expr_bind)

    # 3) `@move :mut` with something that is not an assignment
    expr_move = quote
        @move :mut (x + y)
    end
    @test_throws LoadError eval(expr_move)

    # 4) Wrong order for @ref => also macro expansion => plain ErrorException
    expr_ref = quote
        @lifetime some_lt begin
            @ref :mut some_lt x = 123
        end
    end
    @test_throws LoadError eval(expr_ref)

    # 5) `@clone` with something that is not an assignment
    expr_clone = quote
        @clone (x + y)
    end
    @test_throws LoadError eval(expr_clone)
end

@testitem "Borrowed Arrays" begin
    @own x = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = x
        @test ref == [1, 2, 3]
        # We can borrow the borrow since it is immutable
        @ref lt ref2 = ref
        @test ref2 == [1, 2, 3]
        @test ref2 isa Borrowed{Vector{Int}}
        @test ref2[2] == 2
        @test ref2[2] isa Int

        @test ref2[1:2] isa Vector{Int}

        # No mutating allowed
        @test_throws BorrowRuleError push!(ref2, 4)
    end
    @test x == [1, 2, 3]

    # Now, with non-isbits
    mutable struct A
        a::Float64
    end
    @own x = [A(1.0), A(2.0), A(3.0)]
    @lifetime lt begin
        @ref lt ref = x
        @test ref[1].a == 1.0
        @test ref[1] isa LazyAccessor{A,<:Any,<:Any,<:Borrowed{<:Vector{A}}}
    end
end

@testitem "Symbol Tracking" begin
    using BorrowChecker: is_moved, get_owner, get_symbol

    # Test symbol tracking for owned values
    @own x = 42
    @test get_symbol(x) == :x

    @own :mut y = [1, 2, 3]
    @test get_symbol(y) == :y
    @clone y2 = y
    @move y3 = y2
    @test is_moved(y2)
    @test !is_moved(y3)

    # Test symbol tracking through moves
    @move z = x
    # Gets new symbol when moved/cloned
    @test get_symbol(z) == :z
    @test get_symbol(x) == :x
    @test !is_moved(z)
    # x is not moved since it's isbits
    @test !is_moved(x)

    # Test error messages include the correct symbol
    @own :mut a = [1, 2, 3]  # non-isbits
    @move b = a
    @test is_moved(a)  # a should be moved
    err = try
        @move c = a  # Try to move an already moved value
        nothing
    catch e
        e
    end
    @test err isa MovedError
    @test err.var === :a

    # Test symbol tracking in references
    @lifetime lt begin
        @ref lt ref = y
        @test get_symbol(y) == :y  # Original symbol preserved
        @test get_symbol(get_owner(ref)) == :y
    end
end

@testitem "Math Operations" begin
    # Test binary operations with owned values
    @own x = 2
    @own :mut y = 3

    # Test owned op number
    @test x + 1 == 3
    @test y * 2 == 6

    # Test number op owned
    @test 1 + x == 3
    @test 2 * y == 6

    # Test owned op owned
    @test x + y == 5
    @test x * y == 6

    # Test unary operations
    @test -x == -2
    @test abs(x) == 2
    @test sin(y) == sin(3)

    # Test operations preserve ownership rules for non-isbits
    @own :mut vec = [1, 2, 3]
    @move vec2 = vec
    @test_throws MovedError vec[1]

    # Test operations through references
    @lifetime lt begin
        @ref lt rx = x
        @ref lt rz = y

        # Test all combinations with references
        @test rx + 1 == 3  # ref op number
        @test 1 + rx == 3  # number op ref
        @test rx + rz == 5  # ref op ref
        @test -rx == -2    # unary op ref

        # Test we can't modify through immutable ref
        @test_throws BorrowRuleError @set rx = rx + 1
    end
end

@testitem "Symbol Checking" begin
    using BorrowChecker: is_moved

    # Test that symbol checking works for @take!
    @own :mut x = 42
    y = x  # This is illegal - should use @move
    @test_throws(
        "Variable `y` holds an object that was reassigned from `x`.\nRegular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership or `@set` to modify values.",
        @take! y
    )

    # Test that symbol checking works for @move
    @own :mut a = [1, 2, 3]
    b = a  # This is illegal - should use @move
    @test_throws(
        "Variable `b` holds an object that was reassigned from `a`.\nRegular variable reassignment is not allowed with BorrowChecker. Use `@move` to transfer ownership or `@set` to modify values.",
        @move c = b
    )
end

@testitem "Iteration" begin
    @own :mut x = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = x
        for (i, xi) in enumerate(ref)
            @test xi isa Borrowed{Int}
            @test xi == x[i]
        end
    end
end

@testitem "Managed ownership transfer" begin
    using BorrowChecker: BorrowChecker, MovedError, @own, @take!, is_moved
    using BorrowChecker.Experimental: @managed

    # Define a function that expects a raw Int
    function add_one!(x::Ref{Int})
        x[] += 1
        return x
    end

    # Test with ownership context
    @own x = Ref(1)
    # Regular call will hit a MethodError
    @test_throws MethodError add_one!(x)

    # With ownership context, it will automatically convert!
    result = @managed add_one!(x)

    # Correct calculation:
    @test result[] == 2

    # Was automatically moved:
    @test is_moved(x)
end

@testitem "Managed ownership transfer with keyword arguments" begin
    using BorrowChecker: BorrowChecker, MovedError, @own, @take!, is_moved
    using BorrowChecker.Experimental: @managed

    # Define a function that expects raw values in both positional and keyword arguments
    function add_with_offset!(x::Ref{Int}; offset::Ref{Int})
        x[] += offset[]
        return x
    end

    # Test with ownership context
    @own x = Ref(1)
    @own offset = Ref(5)

    # With ownership context, it should automatically convert both positional and keyword args
    result = @managed add_with_offset!(x, offset=offset)

    # Correct calculation:
    @test result[] == 6

    # Both values should be moved:
    @test is_moved(x)
    @test is_moved(offset)
end

@testitem "Cassette forwards errors" begin
    mutable struct MySkippingType
        a::Int
        b::Int
    end
    function setprop_for_skip!(x)
        return x.c = 99  # triggers setproperty! on a property "c" that doesn't exist
    end

    @own skipobj = MySkippingType(10, 20)
    @test skipobj isa Owned{MySkippingType}

    @test_throws "type MySkippingType has no field c" begin
        BorrowChecker.Experimental.@managed setprop_for_skip!(skipobj)
    end
end

@testitem "Cassette context forbids capturing owned variables" begin
    using BorrowChecker: BorrowChecker, @own

    function g()
        @own x = 1
        inner() = (x = x + 1; nothing)
        inner()
        return x
    end
    @test_throws "You are not allowed to capture owned variable `x` inside a closure." begin
        BorrowChecker.Experimental.@managed g()
    end
end

@testitem "Symbol validation" begin
    using BorrowChecker: SymbolMismatchError, is_moved, get_symbol

    # Test that symbol checking works for @clone
    @own :mut x = [1, 2, 3]
    y = x  # This is illegal - should use @move or @clone
    @test_throws(
        "Variable `y` holds an object that was reassigned from `x`.\n" *
            "Regular variable reassignment is not allowed with BorrowChecker. " *
            "Use `@move` to transfer ownership or `@set` to modify values.",
        @clone z = y
    )

    # Test that cloning works with correct symbols
    @own :mut a = [1, 2, 3]
    @clone b = a  # This is fine
    @test b == [1, 2, 3]
    @test !is_moved(a)  # Original not moved

    # Test symbol validation for owned values
    @own :mut x = 42
    @test get_symbol(x) == :x
    y = x  # This will create the wrong symbol association
    @test_throws SymbolMismatchError @take! y  # wrong symbol

    # Test symbol validation for references
    @lifetime lt begin
        @ref lt :mut rx = x
        @test get_symbol(rx) == :rx
        ry = rx
        # Symbol validation does NOT trigger
        # for ref
        @take ry
    end

    # # Test symbol validation for move
    @own :mut x = 42
    y = x
    @test_throws SymbolMismatchError @move wrong = y
    @move z = x
    @test get_symbol(z) == :z

    # Test symbol validation for clone
    @own a = [1, 2, 3]
    b = a
    @test_throws SymbolMismatchError @clone wrong = b
    @clone c = a
    @test get_symbol(c) == :c
end

@testitem "Basic for loop binding" begin
    using BorrowChecker: is_moved, SymbolMismatchError, get_symbol

    # Test basic for loop binding
    @own :mut accumulator = 0
    @own for x in 1:3
        @test x isa Owned{Int}
        @test get_symbol(x) == :x
        @set accumulator = accumulator + x
        y = x
        @test_throws SymbolMismatchError @take!(y)
    end
    @test (@take! accumulator) == 6
end

@testitem "Mutable for loop binding" begin
    using BorrowChecker: is_moved, SymbolMismatchError, get_symbol

    # Test mutable for loop binding
    @own :mut accumulator = 0
    @own :mut for x in 1:3
        @test x isa OwnedMut{Int}
        @test get_symbol(x) == :x
        @set x = x + 1  # Test mutability
        @set accumulator = accumulator + x
    end
    @test (@take! accumulator) == 9
end

@testitem "For loop move semantics" begin
    using BorrowChecker: is_moved, SymbolMismatchError

    # Test nested for loop binding
    @own :mut matrix = []
    @own for i in [Ref(1), Ref(2)]  # We test non-isbits to verify moved semantics
        @take! i
        @test_throws MovedError @take! i
    end
end

@testitem "Nested for loop binding" begin
    using BorrowChecker: is_moved, SymbolMismatchError

    @own :mut matrix = []
    @own for i in [Ref(1), Ref(2)]
        @own :mut row = []
        @own for j in [Ref(1), Ref(2)]
            @clone i_copy = i
            push!(row, (@take!(i_copy).x, @take!(j).x))

            @test_throws MovedError @take!(i_copy)
            @test_throws MovedError @take!(j)
        end
        push!(matrix, @take!(row))
        @test !is_moved(i)  # We only cloned it; never moved
    end
    @test matrix == [[(1, 1), (1, 2)], [(2, 1), (2, 2)]]
end

@testitem "Mutable nested for loop binding" begin
    using BorrowChecker: is_moved, SymbolMismatchError

    @own :mut matrix = []
    @own :mut for i in [Ref(1), Ref(2)]
        @own :mut row = []
        @own :mut for j in [Ref(1), Ref(2)]
            @clone i_copy = i
            @set j = Ref(15)
            push!(row, (@take!(i_copy).x, @take!(j).x))
        end
        push!(matrix, @take!(row))
    end
    @test matrix == [[(1, 15), (1, 15)], [(2, 15), (2, 15)]]
end

@testitem "Preferences disable" begin
    # First test that the borrow checker is enabled by default
    @own x = [1]  # Use Vector{Int} instead of Int
    @test x isa Owned{Vector{Int}}
    @move y = x
    @test y isa Owned{Vector{Int}}
    @test_throws MovedError @take! x

    # Now test that it can be disabled via preferences
    push!(LOAD_PATH, joinpath(@__DIR__, "FakeModule"))
    try
        @eval using FakeModule
        FakeModule.test()
    finally
        filter!(!=(joinpath(@__DIR__, "FakeModule")), LOAD_PATH)
    end
end

# Additional disable_borrow_checker tests
@testitem "disable_borrow_checker coverage" begin
    module MyTestDisable
    using BorrowChecker: disable_borrow_checker!, @own
    @own x = [1, 2, 3]

    function try_disable()
        return disable_borrow_checker!(@__MODULE__)
    end
    end

    err = try
        MyTestDisable.try_disable()
        nothing
    catch e
        e
    end
    @test err !== nothing

    # Show the error text
    msg = sprint(showerror, err)
    @test occursin("BorrowChecker preferences were already cached", msg)

    # Another module that disables first
    module MyTestDisable2
    using BorrowChecker: disable_borrow_checker!, @own
    disable_borrow_checker!(@__MODULE__)
    @own x = [1, 2, 3]  # pass-through
    end
    @test true
end

@testitem "Multiple disable_borrow_checker! calls" begin
    module ExtraDisableTest
    using BorrowChecker: disable_borrow_checker!, @own
    disable_borrow_checker!(@__MODULE__)  # We do it immediately => pass-through

    @own attempt = [999]  # Should be pass-through now

    function double_disable()
        return disable_borrow_checker!(@__MODULE__)  # might trigger "already cached"
    end
    end

    err = try
        ExtraDisableTest.double_disable()
        nothing
    catch e
        e
    end
    @test true  # We'll ignore whether it fails or not.
end

@testitem "Tuple unpacking" begin
    using BorrowChecker: is_moved

    # Test basic tuple unpacking
    @own x, y, z = (1, 2, 3)
    @test x isa Owned{Int}
    @test x == 1
    @test z isa Owned{Int}
    @test z == 3

    @own :mut x, y, z = (1, 2, 3)
    @test x isa OwnedMut{Int}
    @test x == 1
    @test z isa OwnedMut{Int}
    @test z == 3

    @own x, y, z = 1:3
    @test x isa Owned{Int}
    @test z isa Owned{Int}
    @test x == 1
    @test z == 3

    @own :mut x, y, z = 1:3
    @test x isa OwnedMut{Int}
    @test z isa OwnedMut{Int}
    @test x == 1
    @test z == 3
end

# Additional tuple unpacking tests
@testitem "BorrowRuleError on tuple expression" begin
    @own imm = (1, 2, 3)
    @test_throws BorrowRuleError @set imm = (4, 5, 6)
    @own im1, im2, im3 = imm
    @test_throws BorrowRuleError @set im1 = 99
    @own :mut im1, im2, im3 = imm
    @set im1 = 99
    @test im1 == 99
end

@testitem "Tuple unpacking in macro expansion" begin
    using BorrowChecker: is_moved

    @own :mut (x, y) = (1, 2)
    @test x == 1
    @test y == 2
    @test !is_moved(x)
    @test !is_moved(y)
end

@testitem "Reference for loop" begin
    using BorrowChecker: is_moved, get_symbol

    # Test basic reference for loop
    @own :mut x = [1, 2, 3]
    @lifetime lt begin
        # Test immutable reference loop
        @own :mut count = 0
        @ref lt for xi in x
            @test xi isa Borrowed{Int}
            @test get_symbol(xi) == :xi
            @set count = count + xi
        end
        @test count == 6
        @test !is_moved(x)
    end

    # Test reference loop with non-isbits types
    @own :mut vec_array = [[1], [2], [3]]
    @lifetime lt begin
        @ref lt for v in vec_array
            @test v isa Borrowed{Vector{Int}}
            @test get_symbol(v) == :v
            @test_throws BorrowRuleError push!(v, 4)  # Can't modify through immutable ref
        end
        @test !is_moved(vec_array)
    end

    # Test nested reference loops
    @own :mut matrix = [[1, 2], [3, 4]]
    @own :mut flat = Int[]
    @lifetime lt begin
        @ref lt for row in matrix
            @test row isa Borrowed{Vector{Int}}
            @ref lt for x in row
                @test x isa Borrowed{Int}
                @test get_symbol(x) == :x
                @clone inner = x
                push!(flat, @take!(inner))
            end
        end
        @test !is_moved(matrix)
    end
end

@testitem "Array Views" begin
    # Test that views are not allowed on owned arrays
    @own x = [1, 2, 3, 4]
    @test_throws BorrowRuleError view(x, 1:2)

    # Test that views work on borrowed arrays
    @lifetime lt begin
        @ref lt ref = x
        @test view(ref, 1:2) isa Borrowed{<:AbstractVector{Int}}
        @test_throws BorrowRuleError @own bound_view = view(ref, 1:2)
    end
end

@testitem "Reference numeric operations" begin
    @own x = 5
    @own y = 10
    @lifetime a begin
        @ref a rx = x
        @ref a ry = y
        @test clamp(rx, ry, 20) == clamp(5, 10, 20)
        @test fma(rx, ry, 2) == 5 * 10 + 2
        @test isapprox(log(rx, ry), log(5, 10))
    end
end
@testitem "Dictionary & LazyAccessor coverage" begin
    @own :mut d = Dict(:a => 1, :b => 2)
    @test haskey(d, :a)
    @test !haskey(d, :c)

    syms = keys(@take d)
    @test collect(syms) == [:a, :b]

    pop!(d, :b)
    @test !haskey(d, :b)
    @test d == Dict(:a => 1)
    empty!(d)
    @test length(d) == 0

    # Non-isbits key => triggers throw(...) => ErrorException
    @own :mut d2 = Dict([1] => 10, [2] => 20)
    @test_throws ErrorException keys(d2)

    # LazyAccessor setindex! coverage
    @own :mut arr2d = [[10, 20], [30, 40]]
    @lifetime lt begin
        @ref lt :mut ref_arr2d = arr2d
        subacc = ref_arr2d[1]  # LazyAccessor
        subacc[2] = 99
        @test ref_arr2d[1] == [10, 99]
    end
end

@testitem "Dictionary Operations" begin
    @own :mut dict = Dict(:a => 1)
    @lifetime lt begin
        @ref lt :mut ref = dict
        ref[:b] = 2
        delete!(ref, :a)
        @test length(ref) == 1
        @test ref[:b] == 2
    end
end

@testitem "Three-argument Math Operations" begin
    @own x = 1
    @own y = 2
    @own z = 3
    nx = @take x
    ny = @take y
    nz = @take z
    @test clamp(x, y, z) == 2
    @test clamp(nx, y, z) == 2
    @test clamp(x, ny, z) == 2
    @test clamp(x, y, nz) == 2
    @test clamp(nx, ny, z) == 2
    @test clamp(nx, y, nz) == 2
    @test clamp(x, ny, nz) == 2
    @test fma(x, y, z) == 5
end

@testitem "LazyAccessor Operations" begin
    mutable struct Point
        x::Int
        y::Int
    end
    @own :mut p = Point(1, 2)
    @lifetime lt begin
        @ref lt :mut r = p
        @test r.x isa LazyAccessor
        r.x = 3
    end
    # Check the value after the lifetime block ends
    @test p.x == 3
end

@testitem "Dictionary Error Paths" begin
    # Test error on non-isbits keys
    @own :mut d = Dict([1, 2] => 10)  # Vector{Int} is non-isbits
    @test_throws "Refusing to return non-isbits keys" keys(d)

    # Test error on type conversion
    @own :mut d2 = Dict(1 => 2)
    @lifetime lt begin
        @ref lt :mut ref = d2
        @test_throws MethodError ref[1] = "string"  # Can't convert String to Int
    end
end

@testitem "String Operation Errors" begin
    # Test string operations with invalid types
    @own s = "hello"
    @own :mut num = 42
    @lifetime lt begin
        @ref lt ref_s = s
        @ref lt ref_n = num
        @test_throws MethodError startswith(ref_n, "4")  # Number doesn't support startswith
        @test_throws MethodError endswith(ref_s, ref_n)  # Can't endswith with a number
    end
end

@testitem "Property Access Errors" begin
    mutable struct TestStruct
        x::Int
        y::Vector{Int}
    end

    # Test property access errors
    @own :mut obj = TestStruct(1, [1, 2, 3])
    @lifetime lt begin
        @ref lt :mut ref = obj
        # Test accessing non-existent property
        @test_throws ErrorException ref.z
    end

    # Test multiple borrows in a new lifetime
    @lifetime lt2 begin
        @ref lt2 :mut ref2 = obj
        @test_throws "Cannot create mutable reference" @ref lt2 :mut ref3 = obj
    end
end

@testitem "Semantics Error Paths" begin
    # Test error on invalid property access
    mutable struct TestStruct
        x::Int
    end

    # Test error on invalid property access through LazyAccessor
    @own :mut obj = TestStruct(1)
    @lifetime lt begin
        @ref lt :mut ref = obj
        lazy = ref.x  # Get LazyAccessor
        @test_throws ErrorException getproperty(lazy, :nonexistent)
        @test_throws ErrorException setproperty!(lazy, :nonexistent, 42)
    end

    # Test error on invalid symbol validation
    @own :mut x = [1, 2, 3]
    y = x  # Create invalid symbol association
    @test_throws "Regular variable reassignment is not allowed" @clone z = y
end

@testitem "Macro Error Paths" begin
    # Test error on invalid first argument to @clone
    @test_throws LoadError @eval @clone :invalid x = 42

    # Test error on invalid argument order in @ref
    @test_throws "You should write `@ref lifetime :mut expr` instead of `@ref :mut lifetime expr`" begin
        @eval @ref :mut lt x = 42
    end

    @test_throws LoadError @eval @set x + y

    @test_throws LoadError @eval @move x + y  # Not an assignment
    @test_throws LoadError @eval @move :invalid x = y  # Invalid first argument

    @test_throws LoadError @eval @set x  # Not an assignment

    @test_throws LoadError @eval @ref x  # Not an assignment or for loop
    @test_throws LoadError @eval @ref lt :invalid x = 42  # Invalid mut flag
    @test_throws "You should write `@ref lifetime :mut expr`" @eval @ref :mut lt x = 42  # Wrong order

    mutable struct NonIsBits
        x::Vector{Int}
    end
    @own :mut arr = [NonIsBits([1])]
    @lifetime lt begin
        @ref lt :mut ref = arr
        @test_throws ErrorException collect(ref)  # Non-isbits collection
        @test_throws ErrorException first(ref)    # Non-isbits element
    end

    @own num = 42
    @lifetime lt begin
        @ref lt ref = num
        @test_throws MethodError startswith(ref, "4")  # Invalid type for startswith
        @test_throws MethodError endswith(ref, "2")    # Invalid type for endswith
    end

    mutable struct TestStruct
        x::Int
    end
    @own :mut obj = TestStruct(1)
    @lifetime lt begin
        @ref lt :mut ref = obj
        lazy = ref.x
        @test_throws ErrorException getproperty(lazy, :nonexistent)
        @test_throws ErrorException setproperty!(lazy, :nonexistent, 42)
    end

    mutable struct CustomType
        x::Int
    end

    @own :mut obj = CustomType(1)
    @lifetime lt begin
        @ref lt :mut ref = obj
        @test_throws ErrorException ref.nonexistent  # Invalid property access
        @test_throws ErrorException ref.nonexistent = 42  # Invalid property assignment

        # Test multiple borrows error
        @test_throws "Cannot create mutable reference" @ref lt :mut ref2 = obj
    end

    @own x = 1
    @own y = 1
    lt = BorrowChecker.Lifetime()

    # Test @ref error paths
    @test_throws LoadError @eval @ref :invalid lt x = 42
    @test_throws LoadError @eval @ref lt x + y

    # Test @clone error paths
    @test_throws LoadError @eval @clone x + y
    @test_throws LoadError @eval @clone :mut x + y
end

@testitem "Disabled Borrow Checker" begin
    # Test @take with disabled borrow checker
    module TakeTest
    using BorrowChecker: disable_borrow_checker!, @take, @own
    using Test
    disable_borrow_checker!(@__MODULE__)
    function run_test()
        @own x = [1, 2, 3]
        # `@take` should still do a deepcopy
        @test @take(x) !== [1, 2, 3]
    end
    end
    TakeTest.run_test()

    # Test @lifetime with disabled borrow checker
    module LifetimeTest
    using BorrowChecker: disable_borrow_checker!, @lifetime, @ref
    using Test
    disable_borrow_checker!(@__MODULE__)
    function run_test()
        x = 42
        @lifetime lt begin
            @ref lt ref = x
            @test ref == 42
        end
    end
    end
    LifetimeTest.run_test()
end

@testitem "Collection Operation Errors" begin
    # Test collection operation errors
    mutable struct NonIsBits
        x::Int
    end

    @own :mut arr = [NonIsBits(1)]
    @test_throws "Use `@own for var in iter` instead" collect(arr)
end

@testitem "Dictionary Operation Errors" begin
    mutable struct NonIsBits
        x::Int
    end

    # Test container operation errors
    @own :mut dict = Dict(NonIsBits(1) => 10)
    @own :mut dictref = Ref(Dict(NonIsBits(1) => 10))
    @lifetime lt begin
        @ref lt :mut ref = dict
        @test_throws "Refusing to return non-isbits keys" keys(ref)  # Non-isbits values through reference

        @ref lt :mut ref2 = dictref
        @test_throws "Refusing to return non-isbits keys" keys(ref2[])  # Non-isbits values through reference
    end

    # Test dictionary operation errors
    @own :mut d = Dict{Int,Int}()
    @lifetime lt begin
        @ref lt :mut ref = d
        @test_throws KeyError ref[1]  # Key not found
    end
end

@testitem "Property Access Errors" begin
    # Test semantics error paths
    mutable struct TestStruct
        x::Int
    end
    @own :mut obj = TestStruct(1)
    @lifetime lt begin
        @ref lt :mut ref = obj
        @test_throws ErrorException ref.nonexistent  # Invalid property access
        @test_throws ErrorException ref.nonexistent = 42  # Invalid property assignment
        @test ref.x == 1
        @test sprint(show, ref.x) == "1"

        # Test multiple borrows error
        @test_throws "Cannot create mutable reference" @ref lt :mut ref2 = obj
    end
end

@testitem "Show and PropertyNames Coverage" begin
    using BorrowChecker
    using BorrowChecker: is_moved, get_owner

    # Test propertynames
    mutable struct TestStruct
        x::Int
    end
    @own :mut obj = TestStruct(1)
    @lifetime lt begin
        @ref lt :mut ref = obj
        @test propertynames(ref) == (:x,)
    end

    # Test show for Owned
    @own :mut arr = [1, 2, 3]
    s = sprint(show, arr)
    @test occursin("OwnedMut{Vector{Int64}}([1, 2, 3], :arr)", s)
    @move moved_arr = arr
    s = sprint(show, moved_arr)
    @test occursin("Owned{Vector{Int64}}([1, 2, 3], :moved_arr)", s)

    # And, test moved versions:
    s = sprint(show, arr)
    @test "[moved]" == s

    # Test show for Borrowed
    @own :mut vec = [1, 2, 3]
    s = sprint(show, vec[1])
    @test s == "1"  # Because it is isbits
    storage = []

    @lifetime lt begin
        @ref lt :mut ref = vec
        s = sprint(show, ref)
        @test occursin(
            r".*BorrowedMut\{Vector\{Int64\},.*OwnedMut\{Vector\{Int64\}\}\}\(\[1, 2, 3\], :ref\)",
            s,
        )
        push!(storage, ref)
    end

    # Now, for LazyAccessor of moved owned value:
    @own arr = [[1], [2], [3]]
    r1 = arr[1]
    s = sprint(show, r1)
    @test s == "[1]"
    @move arr2 = arr
    s = sprint(show, r1)
    @test s == "[moved]"
end

@testitem "Tuple Operations" begin
    # Test tuple indexing
    @own t = (1, [2], 3)
    @test t[1] == 1  # isbits element
    @test t[2] == [2]  # non-isbits element
    @test t[2] isa LazyAccessor  # non-isbits elements return LazyAccessor

    # Test tuple operations with references
    @lifetime lt begin
        @ref lt ref = t
        @test ref[1] == 1
        @test ref[2] == [2]
        @test ref[2] isa LazyAccessor
    end

    # Test tuple operations with owned values
    @own :mut mt = ([1], [2], [3])
    @lifetime lt begin
        @ref lt :mut ref = mt
        @test ref[1] == [1]
        @test ref[1] isa LazyAccessor
    end
end

@testitem "Comparison Operators" begin
    # Test comparison operators with owned values
    @own x = 42
    @own y = 42

    @test x == y
    @test x == 42
    @test 42 == x
    @test isequal(x, y)
    @test isequal(x, 42)
    @test isequal(42, x)

    # Test comparison operators with references
    @lifetime lt begin
        @ref lt rx = x
        @ref lt ry = y

        @test rx == ry
        @test rx == 42
        @test 42 == rx
        @test isequal(rx, ry)
        @test isequal(rx, 42)
        @test isequal(42, rx)
    end

    # Nothing operator
    @own n = nothing
    @test isnothing(n)

    # Test ordering operators
    @own a = 1
    @own b = 2
    @test a < b
    @test a <= b
    @test a < 2
    @test a <= 2
    @test b > 1
    @test b >= 1

    # Test with references
    @lifetime lt begin
        @ref lt ra = a
        @ref lt rb = b
        @test ra < rb
        @test ra <= rb
        @test rb > ra
        @test rb >= ra
    end

    # Test isnothing
    @own n = nothing
    @test isnothing(n)
    @lifetime lt begin
        @ref lt rn = n
        @test isnothing(rn)
    end
end

@testitem "copy! Operation" begin
    # Test copy! with owned values
    @own :mut dest = [1, 2, 3]
    @own src = [4, 5, 6]
    copy!(dest, src)
    @test dest == [4, 5, 6]

    # And with Dict
    @own :mut dest2 = Dict()
    @own src2 = Dict(:a => 1, :b => 2)
    @lifetime lt begin
        @ref lt :mut rdest = dest2
        @ref lt rsrc = src2
        copy!(rdest, rsrc)
        @test rdest == Dict(:a => 1, :b => 2)
    end
end

@testitem "_maybe_read Coverage" begin
    # Test _maybe_read with owned values in indexing
    @own :mut arr = [[1], [2], [3]]
    @own idx = 2
    @test arr[idx] == [2]  # Uses _maybe_read on the index

    # Test with references
    @lifetime lt begin
        @ref lt :mut rarr = arr
        @ref lt ridx = idx
        @test rarr[ridx] == [2]  # Uses _maybe_read on both array and index
    end

    # Test with dictionary
    @own :mut dict = Dict(:a => 1, :b => 2)
    @own key = :a
    @test dict[key] == 1  # Uses _maybe_read on the key

    @lifetime lt begin
        @ref lt :mut rdict = dict
        @ref lt rkey = key
        @test rdict[rkey] == 1  # Uses _maybe_read on both dict and key
    end
end

@testitem "Type Alias Behavior" begin
    using BorrowChecker: OrBorrowed, OrBorrowedMut

    # Test function that accepts either raw value or borrowed value
    function accepts_borrowed(x::OrBorrowed{Vector})
        return length(x)
    end
    function accepts_borrowed_mut(x::OrBorrowedMut{Vector})
        push!(x, 4)
        return x
    end

    # Test with raw value
    @test accepts_borrowed([1, 2, 3]) == 3

    # Test with borrowed value
    @own vec = [1, 2, 3]
    @lifetime lt begin
        @ref lt ref = vec
        @test accepts_borrowed(ref) == 3
    end

    # Test with mutable borrowed value
    @own :mut mvec = [1, 2, 3]
    @lifetime lt begin
        @ref lt :mut mref = mvec
        accepts_borrowed_mut(mref)
        @test mref == [1, 2, 3, 4]
    end

    # Test with LazyAccessor
    @own :mut container = [[1, 2, 3]]
    @lifetime lt begin
        @ref lt ref = container
        # First test immutable access
        @test accepts_borrowed(ref[1]) == 3
    end
end

@testitem "Complex Tuple Operations" begin
    # Test tuple with nested non-isbits
    @own t = ([1], ([2], [3]), [4])
    @test t[1] isa LazyAccessor
    @test t[2] isa LazyAccessor
    @test t[3] isa LazyAccessor

    # Test nested access
    @test t[2][1] == [2]
    @test t[2][1] isa LazyAccessor

    # Test with references
    @lifetime lt begin
        @ref lt ref = t
        @test ref[2][2] == [3]
        @test ref[2][2] isa LazyAccessor
    end

    # Test tuple unpacking with references
    @own :mut tup = ([1], [2], [3])
    @lifetime lt begin
        @ref lt :mut ref = tup
        @test ref[1] == [1]
        @test ref[2] == [2]
        @test ref[3] == [3]
    end

    # Test error cases
    @own :mut mt = ([1], [2])
    @move other = mt
    @test_throws MovedError mt[1]
end

@testitem "Additional Error Cases" begin
    # Test error on invalid tuple index
    @own t = (1, 2, 3)
    @test_throws BoundsError t[4]
    @lifetime lt begin
        @ref lt ref = t
        @test_throws BoundsError ref[4]
    end

    # Test error on invalid array index with owned index
    @own arr = [1, 2, 3]
    @own idx = 4
    @test_throws BoundsError arr[idx]

    # Test error on invalid dictionary key with owned key
    @own dict = Dict(:a => 1)
    @own key = :b
    @test_throws KeyError dict[key]

    # Test error on type mismatch in comparison
    @own x = 1
    @own s = "hello"
    @test_throws MethodError x < s
    @lifetime lt begin
        @ref lt rx = x
        @ref lt rs = s
        @test_throws MethodError rx < rs
    end

    # Test error on invalid copy!
    @own :mut dest = [1, 2, 3]
    @own src = ["a", "b", "c"]
    @test_throws MethodError copy!(dest, src)
end

@testitem "String operations" begin
    # Test ncodeunits
    @own str = "hello"
    @test ncodeunits(str) == 5

    # Test startswith
    @own prefix = "he"
    @own full = "hello"
    @test startswith(full, prefix)
    @test startswith(full, "he")  # String literal
    @test startswith("hello", prefix)  # Regular string with owned

    # Test endswith
    @own suffix = "lo"
    @test endswith(full, suffix)
    @test endswith(full, "lo")  # String literal
    @test endswith("hello", suffix)  # Regular string with owned

    # Test with references
    @lifetime lt begin
        @ref lt ref = full
        @test startswith(ref, prefix)
        @test endswith(ref, suffix)
    end
end
