module FakeModule

using BorrowChecker
using BorrowChecker.Experimental: @managed
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

    # Test managed() - it should just run functions as-is when disabled
    function expects_raw_int(x::Int)
        return x + 1
    end

    @own w = 42
    # When enabled, managed() would automatically convert w to raw Int,
    # but when disabled it should fail since w is passed as-is
    @own result = @managed expects_raw_int(w)
    @test result == 43  # Function runs normally since w is just a raw Int
    @test w == 42  # w is not moved since managed() is disabled
end

end
