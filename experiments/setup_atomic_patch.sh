#!/bin/bash
# E16 follow-up: checkout with :sequentially_consistent -> :monotonic in src/types.jl.
set -e
REPO=/home/user/BorrowChecker.jl
rm -rf /tmp/bcatomic
mkdir -p /tmp/bcatomic
cp -r "$REPO/src" "$REPO/Project.toml" "$REPO/LICENSE" /tmp/bcatomic/
sed -i 's/:sequentially_consistent/:monotonic/g' /tmp/bcatomic/src/types.jl
echo "patched sites: $(grep -c ':monotonic' /tmp/bcatomic/src/types.jl)"
rm -rf /tmp/atomicenv
mkdir -p /tmp/atomicenv
JULIA_PKG_SERVER="" julia --project=/tmp/atomicenv -e '
using Pkg
Pkg.develop(path="/tmp/bcatomic")
Pkg.add("BenchmarkTools")
' 2>&1 | tail -2
echo "run: julia --project=/tmp/atomicenv experiments/e16_overlay_atomics.jl"
