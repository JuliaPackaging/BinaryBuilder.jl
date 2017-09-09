#!/usr/bin/env julia
using BinaryBuilder

out_path = joinpath(pwd(), "libfoo_tarballs")
rm(out_path; force=true, recursive=true)
mkpath(out_path)

for platform in supported_platforms()
    temp_prefix() do prefix
        cd("build_tests/libfoo") do
            libfoo = LibraryProduct(prefix, "libfoo")
            fooifier = ExecutableProduct(prefix, "fooifier")
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
