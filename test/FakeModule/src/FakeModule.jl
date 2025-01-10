module FakeModule

using BorrowChecker
using Test

function test()
    @bind x = Ref(1)
    @test x isa Base.RefValue{Int}
    @test !(x isa Bound{Base.RefValue{Int}})
    @move y = x
    @test y isa Base.RefValue{Int}
    @test !(y isa Bound)
    # Since borrow checker is disabled, x should still be accessible
    @test x[] == 1
    # @take should just return the value directly
    @test (@take x)[] == 1

    # This error now goes undetected:
    @test x[] == 1

    # Test @set
    @bind :mut z = 1
    @set z = 2
    @test z == 2
    @test z isa Int
    @test !(z isa BoundMut{Int})

    # Test @lifetime and @ref
    @lifetime l begin
        @ref r = z in l
        @test r == 2
        @test r isa Int
        @test !(r isa Borrowed{Int})
        # Should be able to modify z since borrow checker is disabled
        @set z = 3
        @test z == 3
        @test r == 2  # r should just be a copy
    end
end

end
