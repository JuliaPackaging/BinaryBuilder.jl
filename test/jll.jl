using JSON
using UUIDs
using BinaryBuilder: jll_uuid, build_project_dict

module TestJLL end

@testset "JLLs - utils" begin
    @test jll_uuid("Zlib_jll") == UUID("83775a58-1f1d-513f-b197-d71354ab007a")
    @test jll_uuid("FFMPEG_jll") == UUID("b22a6f82-2f65-5046-a5b2-351ab43fb4e5")

    project = build_project_dict("LibFoo", v"1.3.5", [Dependency("Zlib_jll"), Dependency(PackageSpec(name = "XZ_jll", version = v"2.4.6"))])
    @test project["deps"] == Dict("Pkg"      => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                                  "Zlib_jll" => "83775a58-1f1d-513f-b197-d71354ab007a",
                                  "Libdl"    => "8f399da3-3557-5675-b5ff-fb832c97cbdb",
                                  "XZ_jll"   => "ffd25f8a-64ca-5728-b0f7-c24cf3aae800")
    @test project["name"] == "LibFoo_jll"
    @test project["uuid"] == "b250f842-3251-58d3-8ee4-9a24ab2bab3f"
    @test project["compat"] == Dict("julia" => "1.0", "XZ_jll" => "=2.4.6")
    @test project["version"] == "1.3.5"
    # Make sure BuildDependency's don't find their way to the project
    @test_throws MethodError build_project_dict("LibFoo", v"1.3.5", [Dependency("Zlib_jll"), BuildDependency("Xorg_util_macros_jll")])
end

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

        # First: call `get_meta_json` twice, once for each platform, and write the
        # JSON meta data.  In this way we can test that merging multiple JSON
        # objects work correctly.
        for p in platforms
            dict = get_meta_json(
                name,
                version,
                sources,
                # Use a build script depending on the target platform.
                p isa FreeBSD ? libfoo_make_script : libfoo_meson_script,
                [p],
                # The products we expect to be build
                libfoo_products,
                dependencies;
            )
            # Generate the JSON file
            println(buff, JSON.json(dict))
        end

        # Now build for real
        autobuild(
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
            @test @eval TestJLL libfoo_jll.is_available()
        end
    end
end
