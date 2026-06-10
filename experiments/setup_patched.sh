#!/bin/bash
# Create a patched checkout of BorrowChecker with call counters for E11/E14.
set -e
REPO=/home/user/BorrowChecker.jl
PATCH=/tmp/bcpatch
rm -rf "$PATCH"
mkdir -p "$PATCH"
cp -r "$REPO/src" "$REPO/Project.toml" "$REPO/LICENSE" "$PATCH/"

# Counters at top of defs.jl (first file included by auto.jl that we touch is fine
# as long as constants are defined before use; defs.jl is included first).
python3 - << 'EOF'
import re

defs = "/tmp/bcpatch/src/auto/defs.jl"
src = open(defs).read()
counters = """
# --- experiment counters (E11/E14) ---
const BC_N_TRACKED = Base.Threads.Atomic{Int}(0)
const BC_N_OWNED = Base.Threads.Atomic{Int}(0)
const BC_N_KNOWN = Base.Threads.Atomic{Int}(0)
const BC_TRACKED_ARGS = Any[]
const BC_TRACKED_ARGS_LOCK = Base.ReentrantLock()
const BC_LOG_ARGS = Ref(false)
# -------------------------------------

"""
src = counters + src
old = """@inline function _known_effects_get(@nospecialize(f))
    return @lock KNOWN_EFFECTS get(KNOWN_EFFECTS[], f, nothing)
end"""
new = """@inline function _known_effects_get(@nospecialize(f))
    Base.Threads.atomic_add!(BC_N_KNOWN, 1)
    return @lock KNOWN_EFFECTS get(KNOWN_EFFECTS[], f, nothing)
end"""
assert old in src
src = src.replace(old, new)
open(defs, "w").write(src)

irp = "/tmp/bcpatch/src/auto/ir_primitives.jl"
src = open(irp).read()
old = "is_tracked_type(@nospecialize T)::Bool = TypeTracker()(T)"
new = """function is_tracked_type(@nospecialize(T))::Bool
    Base.Threads.atomic_add!(BC_N_TRACKED, 1)
    if BC_LOG_ARGS[]
        @lock BC_TRACKED_ARGS_LOCK push!(BC_TRACKED_ARGS, T)
    end
    return TypeTracker()(T)
end"""
assert old in src
src = src.replace(old, new)
old = "is_owned_type(@nospecialize T)::Bool = OwnedTypeTracker()(T)"
new = """function is_owned_type(@nospecialize(T))::Bool
    Base.Threads.atomic_add!(BC_N_OWNED, 1)
    if BC_LOG_ARGS[]
        @lock BC_TRACKED_ARGS_LOCK push!(BC_TRACKED_ARGS, T)
    end
    return OwnedTypeTracker()(T)
end"""
assert old in src
src = src.replace(old, new)
open(irp, "w").write(src)
print("patched OK")
EOF

# Set up a project that uses the patched checkout
rm -rf /tmp/patchenv
mkdir -p /tmp/patchenv
JULIA_PKG_SERVER="" julia --project=/tmp/patchenv -e '
using Pkg
Pkg.develop(path="/tmp/bcpatch")
Pkg.add("BenchmarkTools")
' 2>&1 | tail -3
echo "patched env ready"
