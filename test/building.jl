@testset "Building libfoo" begin
	# Test building with both `make` and `cmake`, using directory and git repository
    for script in (libfoo_make_script, libfoo_cmake_script, libfoo_meson_script)
        # Do build within a separate temporary directory
        mktempdir() do build_path
            # Create local git repository of `libfoo` sources
            git_path = joinpath(build_path, "libfoo.git")
            mkpath(git_path)

            # Copy files in, commit them.  This is the commit we will build.
            repo = LibGit2.init(git_path)
            LibGit2.commit(repo, "Initial empty commit")
            libfoo_src_dir = joinpath(build_tests_dir, "libfoo")
            run(`cp -r $(libfoo_src_dir)/$(readdir(libfoo_src_dir)) $(git_path)/`)
            for file in readdir(git_path)
                LibGit2.add!(repo, file)
            end
            commit = LibGit2.commit(repo, "Add libfoo files")

            # Add another commit to ensure that the git checkout is getting the right commit.
            open(joinpath(git_path, "Makefile"), "w") do io
                println(io, "THIS WILL BREAK EVERYTHING")
            end
            LibGit2.add!(repo, "Makefile")
            LibGit2.commit(repo, "Break Makefile")

            for source in (DirectorySource(build_tests_dir),
                           GitSource(git_path, bytes2hex(LibGit2.raw(LibGit2.GitHash(commit)))))
                build_output_meta = autobuild(
                    build_path,
                    "libfoo",
                    v"1.0.0",
                    # Copy in the libfoo sources
                    [source],
                    # Use the particular build script we're interested in
                    script,
                    # Build for this platform
                    [platform],
                    # The products we expect to be build
                    libfoo_products,
                    # No dependencies
                    Dependency[];
                    # Don't do audit passes
                    skip_audit=true,
                    # Make one verbose for the coverage.  We do it all for the coverage, Morty.
                    verbose=true,
                )

                @test haskey(build_output_meta, platform)
                tarball_path, tarball_hash = build_output_meta[platform][1:2]

                # Ensure the build products were created
                @test isfile(tarball_path)

                # Ensure that the file contains what we expect
                contents = list_tarball_files(tarball_path)
                @test "bin/fooifier$(platform_exeext(platform))" in contents
                @test "lib/libfoo.$(platform_dlext(platform))" in contents

                # Unpack it somewhere else
                @test verify(tarball_path, tarball_hash)
                testdir = joinpath(build_path, "testdir")
                rm(testdir, recursive=true, force=true)
                mkpath(testdir)
                unpack(tarball_path, testdir)

                # Ensure we can use it
                prefix = Prefix(testdir)
                fooifier_path = joinpath(bindir(prefix), "fooifier$(platform_exeext(platform))")
                libfoo_path = first(filter(f -> isfile(f), joinpath.(libdirs(prefix), "libfoo.$(platform_dlext(platform))")))

                # We know that foo(a, b) returns 2*a^2 - b
                result = 2*2.2^2 - 1.1

                # Test that we can invoke fooifier
                @test !success(`$fooifier_path`)
                @test success(`$fooifier_path 1.5 2.0`)
                @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

                # Test that we can dlopen() libfoo and invoke it directly
                libfoo = Libdl.dlopen_e(libfoo_path)
                @test libfoo != C_NULL
                foo = Libdl.dlsym_e(libfoo, :foo)
                @test foo != C_NULL
                @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
                Libdl.dlclose(libfoo)
            end
        end
    end
end

shards_to_test = expand_cxxstring_abis(expand_gfortran_versions(platform))
if lowercase(get(ENV, "BINARYBUILDER_FULL_SHARD_TEST", "false")) == "true"
    @info("Beginning full shard test... (this can take a while)")
    shards_to_test = supported_platforms()
else
    shards_to_test = [platform]
end

# Expand to all platforms
shards_to_test = expand_cxxstring_abis(expand_gfortran_versions(shards_to_test))

# Perform a sanity test on each and every shard.
@testset "Shard testsuites" begin
    @testset "$(shard)" for shard in shards_to_test

        platforms = [shard]
        mktempdir() do build_path
            products = [
                ExecutableProduct("hello_world_c", :hello_world_c),
                ExecutableProduct("hello_world_cxx", :hello_world_cxx),
                ExecutableProduct("hello_world_fortran", :hello_world_fortran),
                ExecutableProduct("hello_world_go", :hello_world_go),
            ]

            if !(platforms_match(shard, Platform("i686", "windows")) ||
                 platforms_match(shard, Platform("aarch64", "freebsd")))
                # Rust is broken on 32-bit Windows and unavailable on FreeBSD AArch64, let's skip it
                push!(products, ExecutableProduct("hello_world_rust", :hello_world_rust))
            end

            compilers = [:c, :go]
            # Don't even ask for Rust on FreeBSD AArch64
            if !platforms_match(shard, Platform("aarch64", "freebsd"))
                push!(compilers, :rust)
            end

            build_output_meta = autobuild(
                build_path,
                "testsuite",
                v"1.0.0",
                # No sources
                DirectorySource[],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                # Skip Rust on 32-bit Windows, the compiler exists but it's totally unusable
                if [[ "${target}" == i686-*-mingw* ]]; then
                    while which rustc &> /dev/null; do rm $(which rustc); done
                fi
                # Build testsuite
                make -j${nproc} -sC /usr/share/testsuite install
                # Install fake license just to silence the warning
                install_license /usr/share/licenses/libuv/LICENSE
                """,
                # Build for ALL the platforms
                platforms,
                products,
                # Express a dependency on CSL to silence warning for fortran code
                [Dependency("CompilerSupportLibraries_jll")];
                # We need to be able to build go and rust and whatnot
                compilers,
            )

            # Test that we built everything (I'm not entirely sure how I expect
            # this to fail without some kind of error being thrown earlier on,
            # to be honest I just like seeing lots of large green numbers.)
            @test length(keys(platforms)) == length(keys(build_output_meta))

            # Extract our platform's build, run the hello_world tests:
            output_meta = select_platform(build_output_meta, platform)
            if !isnothing(output_meta)
                tarball_path, tarball_hash = output_meta[1:2]

                # Ensure the build products were created
                @test isfile(tarball_path)

                # Unpack it somewhere else
                @test verify(tarball_path, tarball_hash)
                testdir = joinpath(build_path, "testdir")
                mkdir(testdir)
                unpack(tarball_path, testdir)

                prefix = Prefix(testdir)
                for product in products
                    hw_path = locate(product, prefix)
                    @test hw_path !== nothing && isfile(hw_path)

                    with_libgfortran() do
                        @test readchomp(`$hw_path`) == "Hello, World!"
                    end
                end
            end
        end
    end
end

@testset "gfortran linking specialty flags" begin
    # We test things like linking against libgfortran with `$FC` on a couple of troublesome platforms
    x86_64_linux = Platform("x86_64", "linux"; libgfortran_version=v"3")
    aarch64_linux = Platform("aarch64", "linux"; libgfortran_version=v"3")
    ppc64le_linux = Platform("powerpc64le", "linux"; libgfortran_version=v"3")
    armv7l_linux = Platform("armv7l", "linux"; libgfortran_version=v"3")
    x86_64_macos = Platform("x86_64", "macos"; libgfortran_version=v"3")
    i686_windows = Platform("i686", "windows"; libgfortran_version=v"3")
    troublesome_platforms = [
        x86_64_linux,
        ppc64le_linux,
        armv7l_linux,
        aarch64_linux,
        x86_64_macos,
        i686_windows,
    ]
    expected_git_shas = Dict(
        v"4" => Dict(
            x86_64_linux  => Base.SHA1("fb3897274fe9b293eb6bfb65063895946e655114"),
            ppc64le_linux => Base.SHA1("53a4e6c7e7d05bf245a8b794133b963bb1ebb1c2"),
            armv7l_linux  => Base.SHA1("28fc03c35a4d30da70fbdefc69ecc6b6bf93f2fb"),
            aarch64_linux => Base.SHA1("c1c06efddc8bdce7b33fc9d8b6859f3c63e429ea"),
            x86_64_macos  => Base.SHA1("b0f9ef3b42b30f9085d4f9d60c3ea441554c442f"),
            i686_windows  => Base.SHA1("f39858ccc34a63a648cf21d33ae236bfdd706d09"),
        ),
        v"5" => Dict(
            x86_64_linux  => Base.SHA1("743b2eac2e096281a2c69f95a2f58a4583824a84"),
            ppc64le_linux => Base.SHA1("b663282a6101647c0aa87043a632b6cdc08f761f"),
            armv7l_linux  => Base.SHA1("9a3273d5c7a41e7c2a5ab58b6b69db49a8533bc1"),
            aarch64_linux => Base.SHA1("4bab3a85aceb3e589989f1a11a2f092c5038a6e0"),
            x86_64_macos  => Base.SHA1("9ddfd323ed25fc02394067c6e863f1cf826a9e5e"),
            i686_windows  => Base.SHA1("9390a3c24a8e274e6d7245c6c977f97b406bc3f5"),
        ),
        v"6" => Dict(
            x86_64_linux  => Base.SHA1("0b152c2cc8ff2af82f8d2d0adbbe26e0961131ed"),
            ppc64le_linux => Base.SHA1("97b7e5682b3cadc873644931b17894fa2ff05335"),
            armv7l_linux  => Base.SHA1("267b443b17b99ca2a14ea93d2afc2cce51cad05e"),
            aarch64_linux => Base.SHA1("b396b1d94aba8642a68122a3515b26e4397217a0"),
            x86_64_macos  => Base.SHA1("b211e8c87b83e820416757d6d2985bcd19db7f24"),
            i686_windows  => Base.SHA1("ae50af4ca8651cb3c8f71f34d0b66ca0d8f14a99"),
        ),
    )

    @testset "gcc version $(gcc_version)" for gcc_version in (v"4", v"5", v"6")
        mktempdir() do build_path
            build_output_meta = autobuild(
                build_path,
                "gfortran_flags",
                v"1.0.0",
                # No sources
                FileSource[],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                # Build testsuite
                make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                # Install fake license just to silence the warning
                install_license /usr/share/licenses/libuv/LICENSE
                """,
                # Build for a few troublesome platforms
                troublesome_platforms,
                [ExecutableProduct("hello_world_fortran", :hello_world_fortran)],
                # Express a dependency on CSL to silence warning for fortran code
                [Dependency("CompilerSupportLibraries_jll")];
                preferred_gcc_version=gcc_version,
            )

            for p in troublesome_platforms
                # Test build reproducibility
                # Note: for some reasons, GCC for i686 windows gives different results on
                # different systems, while still always reproducible on each of them:
                # https://github.com/JuliaPackaging/BinaryBuilder.jl/pull/1234#issuecomment-1264192726
                @test build_output_meta[p][3] == expected_git_shas[gcc_version][p] skip=(Sys.iswindows(p))
            end

            # Just a simple test to ensure that it worked.
            @test length(keys(build_output_meta)) == length(troublesome_platforms)
        end
    end

    # Test that building something that links against gfortran suggests depending on CSL
    @test_logs (:warn, r"CompilerSupportLibraries_jll") match_mode=:any begin
        mktempdir() do build_path
            p = Platform("x86_64", "linux"; libgfortran_version=v"3")
            build_output_meta = autobuild(
                build_path,
                "csl_dependency",
                v"1.0.0",
                # No sources
                FileSource[],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                # Build testsuite
                make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                # Install fake license just to silence the warning
                install_license /usr/share/licenses/libuv/LICENSE
                """,
                [p],
                [ExecutableProduct("hello_world_fortran", :hello_world_fortran)],
                Dependency[],
            )
            # Test build reproducibility
            @test build_output_meta[p][3] == Base.SHA1("95e005d9b057b3a28af61189b9af5613127416a6")
        end
    end
end

@testset "HostBuildDependency" begin
    # A platform for which we certainly can't run executable
    p = Platform("x86_64", "freebsd")
    mktempdir() do build_path
        build_output_meta = autobuild(
            build_path,
            "host_dep",
            v"1.0.0",
            # No sources
            DirectorySource[],
            # Script: run hello_world from the HostBuildDependency
            raw"""
            hello_world
            """,
            # Platform
            [p],
            Product[],
            # Install `HelloWorldC_jll` for both the target and the host.
            [
                HostBuildDependency("HelloWorldC_jll"),
                Dependency("HelloWorldC_jll"),
            ];
            # Don't do audit passes
            skip_audit=true,
        )
        @test haskey(build_output_meta, p)
    end
end

@testset "Invalid Arguments" begin
    mktempdir() do build_path
        # Test that invalid JLL names both @warn and error()
        @test_logs (:warn, r"BadDependency_jll") (:warn, r"WorseDependency_jll") match_mode=:any begin
            @test_throws ErrorException autobuild(
                build_path,
                "baddeps",
                v"1.0.0",
                # No sources
                FileSource[],
                "true",
                [HostPlatform()],
                Product[],
                # Three dependencies; one good, two bad
                [
                    Dependency("Zlib_jll"),
                    # We hope nobody will ever register something named this
                    Dependency("BadDependency_jll"),
                    Dependency("WorseDependency_jll"),
                ]
            )
        end

        # Test that manually specifying prerelease or build number in our src_version is an error()
        @test_throws ErrorException autobuild(
            build_path,
            "badopenssl",
            v"1.1.1+c",
            GitSource[],
            "true",
            [HostPlatform()],
            Product[],
            Dependency[],
        )
        @test_throws ErrorException autobuild(
            build_path,
            "test",
            v"1.2.3-4",
            GitSource[],
            "true",
            [HostPlatform()],
            Product[],
            Dependency[],
        )
    end

    @test_throws ErrorException build_tarballs(String[], "", v"1.0", GitSource[], "", supported_platforms(; experimental=true), LibraryProduct[], Dependency[])

    @test_throws ErrorException build_tarballs(String[], "1nvalid-name :(", v"4.20.69",
                                               GitSource[], "", supported_platforms(),
                                               LibraryProduct[], Dependency[])
end

@testset "AnyPlatform" begin
    mktempdir() do build_path
        p = AnyPlatform()
        build_output_meta = autobuild(
            build_path,
            "header",
            v"1.0.0",
            # No sources
            DirectorySource[],
            raw"""
            mkdir -p ${includedir}/
            touch ${includedir}/libqux.h
            install_license /usr/share/licenses/MIT
            """,
            [p],
            [FileProduct("include/libqux.h", :libqux_h)],
            # No dependencies
            Dependency[]
        )
        @test haskey(build_output_meta, p)
        @test build_output_meta[p][3] == Base.SHA1("45c55bfed92bd890d6487c58c4c03e07f5fb8829")

        # Test that having a LibraryProduct for AnyPlatform raises an error
        @test_throws ErrorException autobuild(
            build_path,
            "libfoo",
            v"1.0.0",
            [DirectorySource(build_tests_dir)],
            libfoo_cmake_script,
            [AnyPlatform()],
            libfoo_products,
            # No dependencies
            Dependency[]
        )
    end
end

@testset "Building from remote file" begin
    build_output_meta = nothing
    mktempdir() do build_path
        build_output_meta = autobuild(
            build_path,
            "libconfuse",
            v"3.2.2",
            # libconfuse source
            [ArchiveSource("https://github.com/martinh/libconfuse/releases/download/v3.2.2/confuse-3.2.2.tar.gz",
                           "71316b55592f8d0c98924242c98dbfa6252153a8b6e7d89e57fe6923934d77d0")],
            # Build script for libconfuse
            raw"""
            cd $WORKSPACE/srcdir/confuse-*/
            ./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
            make -j${nproc}
            make install
            """,
            # Build for this platform
            [platform],
            # The products we expect to be build
            [LibraryProduct("libconfuse", :libconfuse)],
            # No dependencies
            Dependency[];
            # Don't do audit passes
            skip_audit=true,
        )
    end
    @test haskey(build_output_meta, platform)
end

@testset "Building framework" begin
    mac_shards = filter(p -> Sys.isapple(p), shards_to_test)
    if isempty(mac_shards)
        mac_shards = [Platform("x86_64", "macos")] # Make sure to always also test this using MacOS
    end
    # The framework is only built as a framework on Mac and using CMake, and a regular lib elsewhere
    script = libfoo_cmake_script
    products = [FrameworkProduct("fooFramework", :libfooFramework)]
    # Do build within a separate temporary directory
    mktempdir() do build_path
        products = [FrameworkProduct("fooFramework", :libfooFramework)]

        build_output_meta = autobuild(
            build_path,
            "libfoo",
            v"1.0.0",
            [DirectorySource(build_tests_dir)],
            # Build the test suite, install the binaries into our prefix's `bin`
            libfoo_cmake_script,
            # Build for ALL the platforms
            mac_shards,
            products,
            # No dependencies
            Dependency[];
            verbose=true,
        )
    end
end
