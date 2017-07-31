#!/usr/bin/env julia
using BinDeps2

for platform in BinDeps2.supported_platforms()
    BinDeps2.temp_prefix() do prefix
        cd("build_tests/libfoo") do
            # First, build libfoo
            libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(prefix), "libfoo"))
            fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix), "fooifier"))
            steps = [`make clean`, `make install`]
            dep = BinDeps2.Dependency("foo", [libfoo, fooifier], steps, platform, prefix)

            BinDeps2.build(dep; verbose=true)
        end
    
        # Next, package it up as a .tar.gz file
        tarball_path = BinDeps2.package(prefix, "./libfoo", platform=platform)
        info("Built and saved at $(tarball_path)")
    end
end
