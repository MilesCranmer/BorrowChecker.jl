using TestItems
using BorrowChecker

@testitem "Thread race detection example" begin
    # From https://discourse.julialang.org/t/package-for-rust-like-borrow-checker-in-julia/124442/54

    # This isn't too good of a test, but we want to confirm
    # this syntax still works
    increment_counter!(ref::Ref) = (ref[] += 1)
    function bc_create_thread_race()
        # (Oops, I forgot to make this Atomic!)
        @own :mut shared_counter = Ref(0)
        Threads.@threads for _ in 1:10000
            increment_counter!(@take! shared_counter)
        end
    end
    @test_throws "Cannot use shared_counter: value has been moved" bc_create_thread_race()

    # This is the correct design, and thus won't throw
    function counter(thread_count::Integer)
        @own :mut local_counter = Ref(0)
        for _ in 1:thread_count
            local_counter[] += 1
        end
        @take! local_counter[]
    end
    function bc_correct_counter()
        @own num_threads = 4
        @own total_count = 10000
        @own count_per_thread = total_count ÷ num_threads
        @own :mut tasks = Task[]
        for t_id in 1:num_threads
            @own thread_count = count_per_thread + (t_id == 1) * (total_count % num_threads)
            @own t = Threads.@spawn counter($(@take! thread_count))
            push!(tasks, @take!(t))
        end
        return sum(map(fetch, @take!(tasks)))
    end

    @test bc_correct_counter() == 10000
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

    @own :mut particles = [
        Particle(Point(0.0, 0.0), Point(1.0, 1.0)),
        Particle(Point(0.0, 0.0), Point(1.0, -0.5)),
        Particle(Point(0.0, 0.0), Point(2.0, 0.5)),
    ]

    @own nsteps = 100
    @own dt = 0.1
    @own for step in 1:nsteps
        @lifetime a let
            @ref ~a :mut for p in particles
                update_velocity!(p, @take(dt))
            end

            # Not allowed:
            if step == 0
                @test_throws "Cannot access original" @ref ~a :mut particles2 = particles
            end
        end
    end

    @test particles[2].position.x ≈ (0.0 + 1.0 * nsteps * dt)
    @test particles[2].position.y ≈ (0.0 - 0.5 * nsteps * dt)

    # If we had repeated the references, this would have broken:
    @test_throws "Cannot access original while mutably borrowed" begin
        @lifetime a let
            for _ in 1:nsteps
                @ref ~a :mut for p in particles
                    update_velocity!(p, @take(dt))
                end
            end
        end
    end
end

@testitem "Usage example 3" begin
    using BorrowChecker

    struct Point
        x::Float64
        y::Float64
    end

    @own :mut points = [Ref(Point(rand(2)...)) for _ in 1:100]
    @clone points_clone = points
    @own perturbation = Point(rand(2)...)
    @lifetime a begin
        @ref ~a :mut for p in points
            p[] = Point(p[].x + perturbation.x, p[].y + perturbation.y)
        end
    end

    raw_points = @take! points
    @test all(
        i -> raw_points[i][].x ≈ points_clone[i][].x + perturbation.x, eachindex(raw_points)
    )
    @test all(
        i -> raw_points[i][].y ≈ points_clone[i][].y + perturbation.y, eachindex(raw_points)
    )
end
