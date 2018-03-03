#!/usr/bin/env julia
using BinaryBuilder

# First, package up the libfoo source so `build_tarballs()` can take it:
src_prefix = Prefix("./build_tests/libfoo")
src_tarball, src_hash = package(src_prefix, "./downloads/libfoo"; verbose=true, force=true)

# Our sources are local.  No biggie.
sources = [
    (src_tarball, src_hash)
]

# Build script is very complicated.
script = raw"""
make install
"""

# By default, we build for all platforms.
platforms = supported_platforms()

# These are the products we care about
products(prefix) = [
    LibraryProduct(prefix, "libfoo", :libfoo),
    ExecutableProduct(prefix, "fooifier", :fooifier)
]

# Dependencies that must be installed before this package can be built
dependencies = [
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, "libfoo", sources, script, platforms, products, dependencies)

# Cleanup temporary sources
rm(src_tarball; force=true)
rm("$(src_tarball).sha256"; force=true)
