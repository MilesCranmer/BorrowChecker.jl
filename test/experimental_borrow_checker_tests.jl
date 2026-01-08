@testitem "Experimental @borrow_checker" tags=[:unstable] begin
    using TestItems
    using BorrowChecker

    using BorrowChecker.Experimental: BorrowCheckError

    mutable struct Box
        x::Int
    end

    mutable struct A
        x::Int
    end

    struct B
        a::A
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_alias()
        x = [1, 2, 3]
        y = x
        x[1] = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_copy()
        x = [1, 2, 3]
        y = copy(x)
        x[1] = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_unknown_call(f)
        x = [1, 2, 3]
        f(x)
        x[1] = 0
        return x
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_alias_mutable_struct()
        x = Box(1)
        y = x
        x.x = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_copy_mutable_struct()
        x = Box(1)
        y = Box(x.x)
        x.x = 0
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_struct_of_struct()
        a = A(1)
        b = B(a)
        c = b
        b.a.x = 0
        return c
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_struct_of_struct()
        a = A(1)
        b = B(a)
        c = B(A(b.a.x))
        b.a.x = 0
        return c
    end

    @testset "g!(y) should not require deleting x" begin
        g!(x) = (push!(x, 1); nothing)

        BorrowChecker.Experimental.@borrow_checker function _bc_g_alias_ok()
            x = [1, 2, 3]
            y = x
            g!(y)
            return y
        end

        @test _bc_g_alias_ok() == [1, 2, 3, 1]
    end

    @test_throws BorrowCheckError _bc_bad_alias()
    @test _bc_ok_copy() == [1, 2, 3]
    @test_throws BorrowCheckError _bc_bad_unknown_call(identity)

    @test_throws BorrowCheckError _bc_bad_alias_mutable_struct()
    @test _bc_ok_copy_mutable_struct().x == 1

    @test_throws BorrowCheckError _bc_bad_struct_of_struct()
    @test _bc_ok_struct_of_struct().a.x == 1

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_body_with_arg(z)
        f = () -> begin
            x = z
            y = x
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_body_0arg()
        f = () -> begin
            x = [1, 2, 3]
            y = copy(x)
            push!(x, 9)
            return y
        end
        return f()
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_body_with_arg(z)
        f = () -> begin
            x = copy(z)
            y = copy(x)
            push!(x, 9)
            return y
        end
        return f()
    end

    @test_throws BorrowCheckError _bc_bad_closure_body_0arg()
    @test_throws BorrowCheckError _bc_bad_closure_body_with_arg([1, 2, 3])
    @test _bc_ok_closure_body_0arg() == [1, 2, 3]
    @test _bc_ok_closure_body_with_arg([1, 2, 3]) == [1, 2, 3]

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_phi_ternary(cond::Bool)
        x = [1, 2, 3]
        y = cond ? x : x
        push!(y, 1)
        return y
    end

    @noinline _ret1(x) = x

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_identity_call()
        x = [1, 2, 3]
        y = _ret1(x)
        push!(y, 1)
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_view_alias()
        x = [1, 2, 3, 4]
        y = view(x, 1:2)
        push!(x, 9)
        return collect(y)
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_capture()
        x = [1, 2, 3]
        y = x
        f = () -> (push!(x, 9); nothing)
        f()
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_bad_closure_capture_nested()
        x = [1, 2, 3]
        y = x
        f = () -> begin
            g = () -> (push!(x, 9); nothing)
            g()
            return nothing
        end
        f()
        return y
    end

    BorrowChecker.Experimental.@borrow_checker function _bc_ok_closure_capture_readonly()
        x = [1, 2, 3]
        y = x
        f = () -> begin
            s = 0
            for i in 1:length(y)
                s += y[i]
            end
            return s
        end
        f()
        return x
    end

    @test _bc_ok_phi_ternary(true) == [1, 2, 3, 1]
    @test _bc_ok_phi_ternary(false) == [1, 2, 3, 1]
    @test _bc_ok_identity_call() == [1, 2, 3, 1]
    @test_throws BorrowCheckError _bc_bad_view_alias()
    @test_throws BorrowCheckError _bc_bad_closure_capture()
    @test_throws BorrowCheckError _bc_bad_closure_capture_nested()
    @test _bc_ok_closure_capture_readonly() == [1, 2, 3]
end
