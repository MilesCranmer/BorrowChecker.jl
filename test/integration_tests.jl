using TestItems
using BorrowChecker

@testitem "Thread race detection example" begin
    # From https://discourse.julialang.org/t/package-for-rust-like-borrow-checker-in-julia/124442/54

    # This isn't too good of a test, but we want to confirm
    # this syntax still works
    increment_counter!(ref::Ref) = (ref[] += 1)
    function bc_create_thread_race()
        # (Oops, I forgot to make this Atomic!)
        @bind :mut shared_counter = Ref(0)
        Threads.@threads for _ in 1:10000
            increment_counter!(@take! shared_counter)
        end
    end
    @test_throws "Cannot use shared_counter: value has been moved" bc_create_thread_race()

    # This is the correct design, and thus won't throw
    function counter(thread_count::Integer)
        @bind :mut local_counter = 0
        for _ in 1:thread_count
            @set local_counter = local_counter + 1
        end
        @take! local_counter
    end
    function bc_correct_counter()
        @bind num_threads = 4
        @bind total_count = 10000
        @bind count_per_thread = total_count ÷ num_threads
        @bind :mut tasks = Task[]
        for t_id in 1:num_threads
            @bind thread_count =
                count_per_thread + (t_id == 1) * (total_count % num_threads)
            @bind t = Threads.@spawn counter($(@take! thread_count))
            push!(tasks, @take!(t))
        end
        return sum(map(fetch, @take!(tasks)))
    end

    @test bc_correct_counter() == 10000
end

@testitem "Usage example 1" begin
    using BorrowChecker
    using BorrowChecker: is_moved

    struct Point
        x::Float64
        y::Float64
    end

    mutable struct Particle
        position::Point
        velocity::Point
    end

    function update_velocity!(p::Particle, dt::Float64)
        p.position = Point(
            p.position.x + p.velocity.x * dt, p.position.y + p.velocity.y * dt
        )
        return nothing
    end

    @bind :mut p = Particle(Point(0.0, 0.0), Point(1.0, 1.0))
    @bind dt = 0.1

    BorrowChecker.@managed let
        update_velocity!(p, dt)
    end

    @test is_moved(p)

    # dt is isbits, so isn't moved, but copied
    @test !is_moved(dt)
end

@testitem "Usage example 2" begin
    struct Point
        x::Float64
        y::Float64
    end
    mutable struct Particle
        position::Point
        velocity::Point
    end

    function update_velocity!(p::Union{T,BorrowedMut{T}}, dt::Float64) where {T<:Particle}
        p.position = Point(
            p.position.x + p.velocity.x * dt, p.position.y + p.velocity.y * dt
        )
        return nothing
    end

    @bind :mut particles = [
        Particle(Point(0.0, 0.0), Point(1.0, 1.0)),
        Particle(Point(0.0, 0.0), Point(1.0, -0.5)),
        Particle(Point(0.0, 0.0), Point(2.0, 0.5)),
    ]

    @bind nsteps = 100
    @bind dt = 0.1
    @bind for step in 1:nsteps
        @lifetime a let
            @ref a :mut for p in particles
                update_velocity!(p, @take(dt))
            end

            # Not allowed:
            if step == 0
                @test_throws "Cannot access original" @ref a :mut particles2 = particles
            end
        end
    end

    @test particles[2].position.x ≈ (0.0 + 1.0 * nsteps * dt)
    @test particles[2].position.y ≈ (0.0 - 0.5 * nsteps * dt)

    # If we had repeated the references, this would have broken:
    @test_throws "Cannot access original while mutably borrowed" begin
        @lifetime a let
            for _ in 1:nsteps
                @ref a :mut for p in particles
                    update_velocity!(p, @take(dt))
                end
            end
        end
    end
end
