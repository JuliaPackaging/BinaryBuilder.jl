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
                    # No depenedencies
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
                @test "bin/fooifier$(exeext(platform))" in contents
                @test "lib/libfoo.$(dlext(platform))" in contents

                # Unpack it somewhere else
                @test verify(tarball_path, tarball_hash)
                testdir = joinpath(build_path, "testdir")
                mkpath(testdir)
                unpack(tarball_path, testdir)

                # Ensure we can use it
                prefix = Prefix(testdir)
                fooifier_path = joinpath(bindir(prefix), "fooifier$(exeext(platform))")
                libfoo_path = first(filter(f -> isfile(f), joinpath.(libdirs(prefix), "libfoo.$(dlext(platform))")))

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
    mktempdir() do build_path
        products = Product[
            ExecutableProduct("hello_world_c", :hello_world_c),
            ExecutableProduct("hello_world_cxx", :hello_world_cxx),
            ExecutableProduct("hello_world_fortran", :hello_world_fortran),
            ExecutableProduct("hello_world_go", :hello_world_go),
            ExecutableProduct("hello_world_rust", :hello_world_rust),
        ]

        build_output_meta = autobuild(
            build_path,
            "testsuite",
            v"1.0.0",
            # No sources
            DirectorySource[],
            # Build the test suite, install the binaries into our prefix's `bin`
            raw"""
            # Build testsuite
            make -j${nproc} -sC /usr/share/testsuite install
            # Install fake license just to silence the warning
            install_license /usr/share/licenses/libuv/LICENSE
            """,
            # Build for ALL the platforms
            shards_to_test,
            products,
            # No dependencies
            Dependency[];
            # We need to be able to build go and rust and whatnot
            compilers=[:c, :go, :rust],
        )

        # Test that we built everything (I'm not entirely sure how I expect
        # this to fail without some kind of error being thrown earlier on,
        # to be honest I just like seeing lots of large green numbers.)
        @test length(keys(shards_to_test)) == length(keys(build_output_meta))

        # Extract our platform's build, run the hello_world tests:
        output_meta = select_platform(build_output_meta, platform)
        @test output_meta != nothing
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
                @test strip(String(read(`$hw_path`))) == "Hello, World!"
            end
        end
    end
end

@testset "gfortran linking specialty flags" begin
    # We test things like linking against libgfortran with `$FC` on a couple of troublesome platforms
    for gcc_version in (v"4", v"5", v"6")
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
                [
                    Linux(:x86_64; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                    Linux(:powerpc64le; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                    Linux(:armv7l; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                    Linux(:aarch64; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                    MacOS(:x86_64; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                    Windows(:i686; compiler_abi=CompilerABI(;libgfortran_version=v"3")),
                ],
                [ExecutableProduct("hello_world_fortran", :hello_world_fortran)],
                # No dependencies
                Dependency[];
                preferred_gcc_version=gcc_version,
            )

            # Just a simple test to ensure that it worked.
            @test length(keys(build_output_meta)) == 6
        end
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
                [platform_key_abi()],
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

        # Test that manually specifying a build number in our src_version is an error()
        @test_throws ErrorException autobuild(
            build_path,
            "badopenssl",
            v"1.1.1+c",
            GitSource[],
            "true",
            [platform_key_abi()],
            Product[],
            Dependency[],
        )
    end
end

@testset "AnyPlatform" begin
    mktempdir() do build_path
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
            [AnyPlatform()],
            [FileProduct("include/libqux.h", :libqux_h)],
            # No dependencies
            Dependency[]
        )
        @test haskey(build_output_meta, AnyPlatform())

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
            # No depenedencies
            Dependency[];
            # Don't do audit passes
            skip_audit=true,
        )
    end
    @test haskey(build_output_meta, platform)
end

@testset "Building framework" begin
    mac_shards = filter(p -> p isa MacOS, shards_to_test)
    if isempty(mac_shards)
        mac_shards = [MacOS()] # Make sure to always also test this using MacOS
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
