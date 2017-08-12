#!/usr/bin/env julia
using BinDeps2

mkpath("./libfoo_tarballs")

for platform in BinDeps2.supported_platforms()
    BinDeps2.temp_prefix() do prefix
        cd("build_tests/libfoo") do
            libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(prefix), "libfoo"))
            fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix), "fooifier"))
            steps = [`make clean`, `make install`]
            dep = BinDeps2.Dependency("foo", [libfoo, fooifier], steps, platform, prefix)
            BinDeps2.build(dep; verbose=true)
        end
    
        # Next, package it up as a .tar.gz file
        cd("./libfoo_tarballs") do
            rm("./libfoo_$(platform).tar.gz"; force=true)
            tarball_path = BinDeps2.package(prefix, "./libfoo", platform=platform)
            info("Built and saved at ./libfoo_tarballs/$(tarball_path)")
        end
    end
end
