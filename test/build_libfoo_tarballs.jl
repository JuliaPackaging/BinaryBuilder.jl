#!/usr/bin/env julia
using BinDeps2

mkpath("./libfoo_tarballs")

for platform in supported_platforms()
    temp_prefix() do prefix
        cd("build_tests/libfoo") do
            libfoo = LibraryResult(joinpath(libdir(prefix), "libfoo"))
            fooifier = FileResult(joinpath(bindir(prefix), "fooifier"))
            steps = [`make clean`, `make install`]
            dep = Dependency("foo", [libfoo, fooifier], steps, platform, prefix)
            build(dep; verbose=true)
        end
    
        # Next, package it up as a .tar.gz file
        cd("./libfoo_tarballs") do
            rm("./libfoo_$(platform).tar.gz"; force=true)
            tarball_path = package(prefix, "./libfoo", platform=platform)
            info("Built and saved at ./libfoo_tarballs/$(tarball_path)")
        end
    end
end
