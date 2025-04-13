module FakeModule

using BorrowChecker
using BorrowChecker: @spawn
using Test

function test()
    @own x = Ref(1)
    @test x isa Base.RefValue{Int}
    @test !(x isa Owned{Base.RefValue{Int}})
    @move y = x
    @test y isa Base.RefValue{Int}
    @test !(y isa Owned)
    # Since borrow checker is disabled, x should still be accessible
    @test x[] == 1
    # @take! should just return the value directly
    @test (@take! x)[] == 1
    # This error now goes undetected:
    @test x[] == 1

    @own :mut z = Ref(1)
    z[] = 2
    @test z[] == 2
    @test z isa Base.RefValue{Int}
    @test !(z isa OwnedMut{Base.RefValue{Int}})

    # Test @lifetime and @ref
    @lifetime l begin
        @ref ~l r = z
        @test r[] == 2
        @test r isa Base.RefValue{Int}
        @test !(r isa Borrowed{Base.RefValue{Int}})
        # Should be able to modify z since borrow checker is disabled
        z[] = 3
        @test z[] == 3
        @test r[] == 3
    end

    let
        @own z = [1, 2, 3]
        @own :mut z_mut = [1, 2, 3]
        f(y) = (@test y isa Vector{Int}; y)
        @test @bc(f(z)) === f(z)
        @test @bc(f(@mut(z_mut))) === f(z_mut)
    end

    let
        # This spawn still works because the borrow checker is disabled
        @own x = 1
        @test fetch(@spawn x + 1) == 2
    end
end

end
