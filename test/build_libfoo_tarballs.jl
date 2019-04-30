#!/usr/bin/env julia
using BinaryBuilder
import Pkg

name = "libfoo"
version = v"1.0.0"

# Our sources are local.  No biggie.
sources = [
    "./build_tests/libfoo",
]

# Build script is very complicated.
script = raw"""
make install
"""

# By default, we build for all platforms.
platforms = [Pkg.Linux(:x86_64), Pkg.MacOS(:x86_64)] #supported_platforms()

# These are the products we care about
products(prefix) = [
    LibraryProduct(prefix, "libfoo", :libfoo),
    ExecutableProduct(prefix, "fooifier", :fooifier)
]

# Dependencies that must be installed before this package can be built
dependencies = [
]

# Build the tarballs, and possibly a `build.jl` as well.
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies)
