#!/usr/bin/env julia
using BinaryBuilder

# First, package up the libfoo source so `autobuild()` can take it:
src_prefix = Prefix("./build_tests/libfoo")
src_tarball, src_hash = package(src_prefix, "./downloads/libfoo"; verbose=true, force=true)

# Our sources are local, that's fine
sources = [
    (src_tarball, src_hash)
]

# Choose which platforms to build for; if we've got an argument use that one,
# otherwise default to just building all of them!
build_platforms = supported_platforms()
if length(ARGS) > 0
    build_platforms = platform_key.(split(ARGS[1], ","))
end
info("Building for $(join(triplet.(build_platforms), ", "))")

products = prefix -> [
    LibraryProduct(prefix, "libfoo"),
    ExecutableProduct(prefix, "fooifier")
]

# Build 'em!
autobuild(
    pwd(),
    "libfoo",
    build_platforms,
    sources,
    "make install",
    products,
)

# Cleanup temporary sources
rm(src_tarball; force=true)
rm("$(src_tarball).sha256"; force=true)
