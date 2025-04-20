using Pkg
@info "Creating environment..."
dir = mktempdir()
Pkg.activate(dir; io=devnull)
Pkg.develop(; path=dirname(@__DIR__), io=devnull)
Pkg.add(["JET", "Preferences"]; io=devnull)
@info "Done!"

using Preferences

cd(dir)

Preferences.set_preferences!(
    "BorrowChecker", "dispatch_doctor_mode" => "disable"; force=true
)

using BorrowChecker
using JET

@info "Running tests..."
JET.test_package(BorrowChecker; target_defined_modules=true)
@info "Done!"

@info "test_jet.jl finished"
