## Tests involing building packages and whatnot
build_tests_dir = joinpath(@__DIR__, "build_tests")
libfoo_products = [
    LibraryProduct("libfoo", :libfoo),
    ExecutableProduct("fooifier", :fooifier),
]

libfoo_make_script = raw"""
cd ${WORKSPACE}/srcdir/libfoo
make install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

libfoo_cmake_script = raw"""
mkdir ${WORKSPACE}/srcdir/libfoo/build && cd ${WORKSPACE}/srcdir/libfoo/build
cmake -DCMAKE_INSTALL_PREFIX=${prefix} -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} ..
make install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

libfoo_meson_script = raw"""
mkdir ${WORKSPACE}/srcdir/libfoo/build && cd ${WORKSPACE}/srcdir/libfoo/build
meson .. -Dprefix=${prefix} --cross-file="${MESON_TARGET_TOOLCHAIN}"
ninja install -v

# grumble grumble meson!  Why do you go to all the trouble to build it properly
# in `build`, then screw it up when you `install` it?!  Silly willy.
if [[ ${target} == *apple* ]]; then
    install_name_tool ${prefix}/bin/fooifier -change ${prefix}/lib/libfoo.0.dylib @rpath/libfoo.0.dylib
fi
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""



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

            for source in (build_tests_dir, git_path => bytes2hex(LibGit2.raw(LibGit2.GitHash(commit))))
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
                    [];
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
            [],
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
            [];
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

@testset "Dependency Specification" begin
    mktempdir() do build_path
        @test_logs (:error, r"BadDependency_jll") (:error, r"WorseDependency_jll") match_mode=:any begin
            @test_throws ErrorException autobuild(
                build_path,
                "baddeps",
                v"1.0.0",
                # No sources
                [],
                "true",
                [platform],
                [ExecutableProduct("foo", :foo)],
                # Three dependencies; one good, two bad
                [
                    "Zlib_jll",
                    # We hope nobody will ever register something named this
                    "BadDependency_jll",
                    "WorseDependency_jll",
                ]
            )
        end
    end
end
