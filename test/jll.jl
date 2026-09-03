using TOML
using JSON
using UUIDs
using GitHub
using BinaryBuilder: jll_uuid, build_project_dict, get_github_author_login, Wizard

module TestJLL end

@testset "JLLs - utils" begin
    @testset "jll_uuid" begin
        @test jll_uuid("Zlib_jll") == UUID("83775a58-1f1d-513f-b197-d71354ab007a")
        @test jll_uuid("FFMPEG_jll") == UUID("b22a6f82-2f65-5046-a5b2-351ab43fb4e5")
    end

    @testset "build_project_dict" begin
        project = build_project_dict("LibFoo", v"1.3.5",
            [Dependency("Zlib_jll"),
            Dependency(PackageSpec(name = "XZ_jll"), compat = "=2.4.6"),
            Dependency(PackageSpec(name = "Preferences", uuid = parse(UUID, "21216c6a-2e73-6563-6e65-726566657250"))),
            Dependency("Scratch"),])
        @test project["deps"] == Dict("JLLWrappers" => "692b3bcd-3c85-4b1f-b108-f13ce0eb3210",
                                    "Artifacts"   => "56f22d72-fd6d-98f1-02f0-08ddc0907c33",
                                    "Pkg"         => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                                    "Zlib_jll"    => "83775a58-1f1d-513f-b197-d71354ab007a",
                                    "Libdl"       => "8f399da3-3557-5675-b5ff-fb832c97cbdb",
                                    "XZ_jll"      => "ffd25f8a-64ca-5728-b0f7-c24cf3aae800",
                                    "Preferences" => "21216c6a-2e73-6563-6e65-726566657250",
                                    "Scratch"     => "6c6a2e73-6563-6170-7368-637461726353")
        @test project["name"] == "LibFoo_jll"
        @test project["uuid"] == "b250f842-3251-58d3-8ee4-9a24ab2bab3f"
        @test project["compat"] == Dict(
            "julia" => "1.0",
            "XZ_jll" => "=2.4.6",
            "JLLWrappers" => "1.7.0",
            "Libdl" => "< 0.0.1, 1",
            "Artifacts" => "< 0.0.1, 1",
            "Pkg" => "< 0.0.1, 1",
        )
        @test project["version"] == "1.3.5"
        # Make sure BuildDependency's don't find their way to the project
        @test_throws AssertionError build_project_dict("LibFoo", v"1.3.5", [Dependency("Zlib_jll"), BuildDependency("Xorg_util_macros_jll")])
        # `Pkg` should not be a dependency if we require Julia v1.6.
        @test !haskey(BinaryBuilder.build_project_dict("foo", v"1.2", Dependency[], "1.6")["deps"], "Pkg")
    end

    @testset "main_tarball_platform" begin
        tarball_platform = BinaryBuilder.main_tarball_platform
        # Not a tarball at all: quietly not our business.  The `.meta.json` case matters --
        # those sit right next to the tarballs, and the pattern used to backtrack
        # catastrophically on them ("match limit exceeded") rather than just not matching.
        @test tarball_platform("") === nothing
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.x86_64-linux-gnu.meta.json") === nothing
        @test tarball_platform("F/Foo_Bar/products/Foo_Bar.v1.2.3.aarch64-linux-gnu-cuda+12.0-cuda_platform+jetson.meta.json") === nothing
        @test tarball_platform("L") === nothing
        # Looks like a tarball, but isn't named like one: worth complaining about
        @test (@test_logs (:warn, r"does not match expected pattern") tarball_platform("F/Foo/products/nonsense.tar.gz")) === nothing
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.any.tar.gz") == AnyPlatform()
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.x86_64-linux-gnu.tar.gz") == Platform("x86_64", "linux")
        @test tarball_platform("F/Foo/products/Foo-logs.v1.2.3.x86_64-linux-gnu.tar.gz") === nothing
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.x86_64-linux-gnu-cxx11.tar.gz") != Platform("x86_64", "linux")
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.x86_64-linux-gnu.tar.gz") != Platform("x86_64", "linux"; cxxstring_abi="cxx11")
        @test tarball_platform("F/Foo/products/Foo.v1.2.3.x86_64-linux-gnu-cxx11.tar.gz") == Platform("x86_64", "linux"; cxxstring_abi="cxx11")
        # The two spellings of the same platform have to land on the same lookup key
        cuda = Platform("aarch64", "linux"; cuda="12.0", cuda_platform="jetson")
        @test tarball_platform("F/Foo_Bar/products/Foo_Bar.v1.2.3.aarch64-linux-gnu-cuda+12.0-cuda_platform+jetson.tar.gz") == cuda
        @test tarball_platform("F/Foo_Bar/products/Foo_Bar.v1.2.3.aarch64-linux-gnu-cuda_platform+jetson-cuda+12.0.tar.gz") == cuda
        @test tarball_platform("F/Foo/Foo@1.2/products/Foo.v1.2.3.x86_64-linux-gnu.tar.gz") == Platform("x86_64", "linux")
    end

    @testset "get_github_author_login" begin
        gh_auth = Wizard.github_auth(;allow_anonymous=true)
        @test get_github_author_login("JuliaPackaging/Yggdrasil", "invalid_hash"; gh_auth) === nothing
        @test get_github_author_login("JuliaPackaging/Yggdrasil", "815de56a4440f4e05333c5295d74f1dc9b73ebe3"; gh_auth) === nothing
        if gh_auth != GitHub.AnonymousAuth()
            @test get_github_author_login("JuliaPackaging/Yggdrasil", "dea7c3fadad16281ead2427f7ab9b32f1c8cb664"; gh_auth) === "Pangoraw"
        end
    end
end

@testset "JLLs - building" begin
    mktempdir() do build_path
        name = "libfoo"
        version = v"1.0.0"
        sources = [DirectorySource(build_tests_dir)]
        # Build for this platform and a platform that isn't this one for sure:
        # FreeBSD.
        freebsd = Platform("x86_64", "freebsd")
        platforms = [platform, freebsd]
        # We depend on Zlib_jll only on the host platform, but not on FreeBSD
        dependencies = [
            Dependency("Zlib_jll"; platforms=[platform]),
            RuntimeDependency("Preferences"; top_level=true)
        ]
        # Augment platform
        augment_platform_block = """
        using Base.BinaryPlatforms
        function augment_platform!(platform::Platform)
            platform["test"] = "enabled"
            return platform
        end
        """
        toplevel_block = """
        const toplevel_marker = 42
        toplevel_available() = is_available()
        const init_saw_toplevel = Ref{Union{Nothing,Int}}(nothing)
        """
        init_block = """
        init_saw_toplevel[] = toplevel_marker
        """
        # Julia compat.  Include Julia v1.6 to exercise the code path which forces lazy
        # artifacts when augmenting the platform
        julia_compat = "1.6"
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
                Sys.isfreebsd(p) ? libfoo_make_script : libfoo_meson_script,
                [p],
                # The products we expect to be build
                libfoo_products,
                dependencies;
                julia_compat,
                init_block,
                augment_platform_block,
                toplevel_block,
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
            @test merged["toplevel_block"] == toplevel_block

            # Determine build version
            name = merged["name"]
            version = merged["version"]
            # Filter out build-time dependencies that will not go into the dependencies of
            # the JLL packages.
            dependencies = Dependency[dep for dep in merged["dependencies"] if is_runtime_dependency(dep)]
            lazy_artifacts = merged["lazy_artifacts"]
            build_version = BinaryBuilder.get_next_wrapper_version(name, version)
            repo = "JuliaBinaryWrappers/$(name)_jll.jl"
            code_dir = BinaryBuilder.codedir(name)
            download_dir = joinpath(build_path, "products")

            # Skip init of the remote repository
            # Filter out build-time dependencies also here
            for json_obj in [merged, objs_unmerged...]
                json_obj["dependencies"] = Dependency[dep for dep in json_obj["dependencies"] if is_runtime_dependency(dep)]
            end

            tag = "$(name)-v$(build_version)"
            upload_prefix = "https://github.com/$(repo)/releases/download/$(tag)"

            # `autobuild` should have left its metadata next to each tarball, so that the
            # rebuild below can skip unpacking and re-hashing them
            for f in readdir(download_dir)
                (endswith(f, ".tar.gz") && !occursin("-logs.", f)) || continue
                @test isfile(joinpath(download_dir, BinaryBuilder.build_meta_path(f)))
            end

            # This loop over the unmerged objects necessary in the event that we have multiple packages being built by a single build_tarballs.jl
            for (i,json_obj) in enumerate(objs_unmerged)
                from_scratch = (i == 1)

                # A test to make sure merging objects and reading them back work
                # as expected.
                if json_obj["platforms"] == [Platform("x86_64", "freebsd")]
                    @test occursin("make install", json_obj["script"])
                else
                    @test occursin("MESON_TARGET_TOOLCHAIN", json_obj["script"])
                end

                BinaryBuilder.rebuild_jll_package(json_obj; download_dir, upload_prefix, verbose=false, from_scratch)
            end

            env_dir = joinpath(build_path, "foo")
            mkpath(env_dir)
            Pkg.activate(env_dir)
            Pkg.develop(PackageSpec(path=code_dir))
            @test isfile(joinpath(code_dir, ".pkg", "select_artifacts.jl"))
            @test read(joinpath(code_dir, ".pkg", "platform_augmentation.jl"), String) == augment_platform_block
            # Make sure the artifacts are lazy because we are augmenting the platform and
            # Julia compat includes versions before v1.7.
            artifacts_toml = TOML.parsefile(joinpath(code_dir, "Artifacts.toml"))
            for artifact in artifacts_toml["libfoo"]
                @test artifact["lazy"]
            end
            # Make sure we use Zlib_jll only in the wrapper for the host
            # platform and not the FreeBSD one.
            platform_wrapper = joinpath(code_dir, "src", "wrappers", triplet(platform) * ".jl")
            freebsd_wrapper = joinpath(code_dir, "src", "wrappers", triplet(freebsd) * ".jl")
            main_src = joinpath(code_dir, "src", name * "_jll.jl")
            @test contains(readchomp(platform_wrapper), "using Zlib_jll")
            @test !contains(readchomp(freebsd_wrapper), "using Zlib_jll")
            @test !contains(readchomp(platform_wrapper), "using Preferences")
            @test !contains(readchomp(freebsd_wrapper),  "using Preferences")
            main_source = readchomp(main_src)
            @test contains(main_source, "using Preferences")
            @test contains(main_source, toplevel_block)
            generate_main_file = findfirst("JLLWrappers.@generate_main_file(", main_source)
            toplevel_marker = findfirst("const toplevel_marker = 42", main_source)
            @test !isnothing(generate_main_file)
            @test !isnothing(toplevel_marker)
            if !isnothing(generate_main_file) && !isnothing(toplevel_marker)
                @test first(generate_main_file) < first(toplevel_marker)
            end
            # Load JLL package and run some actual code from it.
            @eval TestJLL using libfoo_jll
            @test 6.08 ≈ @eval TestJLL ccall((:foo, libfoo), Cdouble, (Cdouble, Cdouble), 2.3, 4.5)
            @test @eval TestJLL libfoo_jll.is_available()
            @test (@eval TestJLL libfoo_jll.toplevel_marker) == 42
            @test @eval TestJLL libfoo_jll.toplevel_available()
            @test (@eval TestJLL libfoo_jll.init_saw_toplevel[]) == 42

            # Toplevel definitions must also be available when no wrapper matches the host.
            freebsd_obj = only(obj for obj in objs_unmerged if obj["platforms"] == [freebsd])
            unavailable_name = "libfoo_unavailable"
            unavailable_code_dir = joinpath(build_path, "unavailable_jll")
            BinaryBuilder.rebuild_jll_package(
                unavailable_name,
                build_version,
                freebsd_obj["sources"],
                freebsd_obj["platforms"],
                freebsd_obj["products"],
                freebsd_obj["dependencies"],
                download_dir,
                upload_prefix;
                code_dir = unavailable_code_dir,
                julia_compat,
                init_block,
                augment_platform_block,
                toplevel_block,
            )
            Pkg.develop(PackageSpec(path=unavailable_code_dir))
            @eval TestJLL using libfoo_unavailable_jll
            @test !(@eval TestJLL libfoo_unavailable_jll.is_available())
            @test (@eval TestJLL libfoo_unavailable_jll.toplevel_marker) == 42
            @test !(@eval TestJLL libfoo_unavailable_jll.toplevel_available())
        end
    end
end

@testset "JLLs - product order" begin
    # products are initialized in the order they are listed in the recipe, which matters
    # for libraries that depend on each other without an rpath.
    products = Product[
        LibraryProduct("libqux", :libqux),
        LibraryProduct("libbar", :libbar),
        ExecutableProduct("baz", :baz),
        LibraryProduct("libfoo", :libfoo),
    ]
    products_info = Dict{Product,Any}()
    for p in products
        name = p isa LibraryProduct ? first(p.libnames) : first(p.binnames)
        products_info[p] = Dict("path" => "lib/$(name).so", "soname" => "$(name).so.1")
    end
    platform = Platform("x86_64", "linux")
    build_output_meta = Dict(platform => ("qux.tar.gz", "0"^64, Base.SHA1("0"^40), products_info))
    mktempdir() do code_dir
        BinaryBuilder.build_jll_package("qux", v"1.0.0", [], code_dir, build_output_meta,
                                        Dependency[], "https://example.com"; products)
        wrapper = read(joinpath(code_dir, "src", "wrappers", "$(triplet(platform)).jl"), String)
        declarations = [m.captures[1] for m in eachmatch(r"@declare_\w+_product\((\w+)", wrapper)]
        @test declarations == ["libqux", "libbar", "baz", "libfoo"]
        inits = [m.captures[1] for m in eachmatch(r"@init_\w+_product\(\s*(\w+)", wrapper)]
        @test inits == ["libqux", "libbar", "baz", "libfoo"]
    end
end
