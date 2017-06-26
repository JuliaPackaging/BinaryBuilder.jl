#!/usr/bin/env julia
using BinDeps2

BinDeps2.temp_prefix() do prefix
    cd("build_tests/libfoo") do
        # First, build libfoo
        libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(prefix), "libfoo"))
        fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix), "fooifier"))
        dep = BinDeps2.Dependency("foo", [libfoo, fooifier], [`make install`], prefix)

        BinDeps2.build(dep)
    end    
    
    # Next, package it up as a .tar.gz file
    tarball_path = BinDeps2.package(prefix, "./libfoo")
    info("Built and saved at $(tarball_path)")
end
