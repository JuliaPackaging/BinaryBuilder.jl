using UUIDs
using BinaryBuilder: jll_uuid, build_project_dict

module TestJLL end

@testset "JLLs - building" begin
    mktempdir() do build_path
        name = "libfoo"
        version = v"1.0.0"
        sources = [DirectorySource(build_tests_dir)]
        # Build for this platform and a platform that isn't this one for sure:
        # FreeBSD.
        platforms = [platform, FreeBSD(:x86_64)]
        dependencies = [Dependency("Zlib_jll")]
        # The buffer where we'll write the JSON meta data
        buff = IOBuffer()

        # First: call `autobuild` twice, one for each platform, and write the
        # JSON meta data.  In this way we can test that merging multiple JSON
        # objects work correctly.
        for p in platforms
            autobuild(
                build_path,
                name,
                version,
                sources,
                # Use a build script depending on the target platform.
                p isa FreeBSD ? libfoo_make_script : libfoo_meson_script,
                [p],
                # The products we expect to be build
                libfoo_products,
                dependencies;
                # Generate the JSON file
                meta_json_stream = buff,
            )
        end

        # Now build for real
        build_output_meta = autobuild(
            build_path,
            name,
            version,
            sources,
            # Use the particular build script we're interested in
            libfoo_make_script,
            platforms,
            # The products we expect to be build
            libfoo_products,
            dependencies;
            # Run audit passes to make sure the library has the correct soname
            skip_audit=false,
        )

        withenv(
            "JULIA_PKG_DEVDIR" => joinpath(build_path, "devdir"),
            # Let's pretend to be in Yggdrasil, set the relevant environment
            # variables.
            "YGGDRASIL" => "true",
            "BUILD_SOURCEVERSION" => "0123456789abcdef0123456789abcdef01234567",
            "PROJECT" => "L/$(name)",
        ) do
            # What follows loosely mimics what we do to build JLL packages in
            # Yggdrasil.
            buff = IOBuffer(strip(String(take!(buff))))
            objs = []
            while !eof(buff)
                push!(objs, BinaryBuilder.JSON.parse(buff))
            end

            # Merging modifies `obj`, so let's keep an unmerged version around
            objs_unmerged = deepcopy(objs)

            # Merge the multiple outputs into one
            merged = BinaryBuilder.merge_json_objects(objs)
            BinaryBuilder.cleanup_merged_object!(merged)
            BinaryBuilder.cleanup_merged_object!.(objs_unmerged)

            # Determine build version
            name = merged["name"]
            version = merged["version"]
            # Filter out build-time dependencies that will not go into the dependencies of
            # the JLL packages.
            dependencies = Dependency[dep for dep in merged["dependencies"] if !isa(dep, BuildDependency)]
            lazy_artifacts = merged["lazy_artifacts"]
            build_version = BinaryBuilder.get_next_wrapper_version(name, version)
            repo = "JuliaBinaryWrappers/$(name)_jll.jl"
            code_dir = joinpath(Pkg.devdir(), "$(name)_jll")
            download_dir = joinpath(build_path, "products")

            # Skip init of the remote repository
            # Filter out build-time dependencies also here
            for json_obj in [merged, objs_unmerged...]
                json_obj["dependencies"] = Dependency[dep for dep in json_obj["dependencies"] if !isa(dep, BuildDependency)]
            end

            tag = "$(name)-v$(build_version)"
            upload_prefix = "https://github.com/$(repo)/releases/download/$(tag)"

            # This loop over the unmerged objects necessary in the event that we have multiple packages being built by a single build_tarballs.jl
            for (i,json_obj) in enumerate(objs_unmerged)
                from_scratch = (i == 1)

                # A test to make sure merging objects and reading them back work
                # as expected.
                if json_obj["platforms"] == [FreeBSD(:x86_64)]
                    @test occursin("make install", json_obj["script"])
                else
                    @test occursin("MESON_TARGET_TOOLCHAIN", json_obj["script"])
                end

                BinaryBuilder.rebuild_jll_package(json_obj; download_dir=download_dir, upload_prefix=upload_prefix, verbose=false, lazy_artifacts=json_obj["lazy_artifacts"], from_scratch=from_scratch)
            end

            env_dir = joinpath(build_path, "foo")
            mkpath(env_dir)
            Pkg.activate(env_dir)
            Pkg.develop(PackageSpec(path=code_dir))
            @eval TestJLL using libfoo_jll
            @test 6.08 ≈ @eval TestJLL ccall((:foo, libfoo), Cdouble, (Cdouble, Cdouble), 2.3, 4.5)
        end
    end
end
