#!/usr/bin/env julia
using BinaryBuilder

# First, package up the libfoo source so `autobuild()` can take it:
try
    mkdir("./downloads")
end
src_prefix = Prefix("./build_tests/libfoo")
src_tarball, src_hash = package(src_prefix, "./downloads/libfoo"; verbose=true, force=true)

# Build 'em!
autobuild(
    pwd(),
    "libfoo",
    supported_platforms(),
    [(src_tarball, src_hash)],
    "make clean; make install",
    prefix -> [LibraryProduct(prefix, "libfoo"), ExecutableProduct(prefix, "fooifier")]
)

# Cleanup temporary sources
rm(src_tarball; force=true)
rm("$(src_tarball).sha256"; force=true)
