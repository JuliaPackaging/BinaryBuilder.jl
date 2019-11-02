## Tests involing building packages and whatnot
import BinaryBuilder: exeext, dlext
using Pkg.PlatformEngines

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

            for source in (dirname(libfoo_src_dir), git_path => bytes2hex(LibGit2.raw(LibGit2.GitHash(commit))))
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
                    [],
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

                check_foo(fooifier_path, libfoo_path)
                rm(testdir; recursive=true, force=true)
            end
        end
    end
end

shards_to_test = expand_cxxstring_abis(expand_gfortran_versions(platform))
if lowercase(get(ENV, "BINARYBUILDER_FULL_SHARD_TEST", "false") ) == "true"    
    @info("Beginning full shard test... (this can take a while)")
    shards_to_test = supported_platforms()
else
    shards_to_test = [platform]
end

# Expand to all platforms
shards_to_test = expand_cxxstring_abis(expand_gfortran_versions(shards_to_test))

# Perform a sanity test on each and every shard.
@testset "Shard sanity tests" begin
    mktempdir() do build_path
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
            # Some executable products
            Product[
                ExecutableProduct("hello_world_c", :hello_world_c),
                ExecutableProduct("hello_world_cxx", :hello_world_cxx),
                ExecutableProduct("hello_world_fortran", :hello_world_fortran),
                ExecutableProduct("hello_world_go", :hello_world_go),
                ExecutableProduct("hello_world_rust", :hello_world_rust),
            ],
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
        mkdir(joinpath(build_path, "testdir"))
        unpack(tarball_path, joinpath(build_path, "testdir"))

        # Run the hello_world executables; we add the lib of libquadmath onto
        # the LD_LIBRARY_PATH so that `hello_world_fortran` can find its
        # compiler support libraries, the poor thing.
        csl_path = dirname(first(filter(x -> occursin("libgfortran", x), Libdl.dllist())))
        LIBPATH_var, envsep = if Sys.iswindows()
            ("PATH", ";")
        elseif Sys.isapple()
            ("DYLD_FALLBACK_LIBRARY_PATH", ":")
        else
            ("LD_LIBRARY_PATH", ":")
        end

        withenv(LIBPATH_var => string(csl_path, envsep, get(ENV, LIBPATH_var, ""))) do
            testbin_dir = joinpath(build_path, "testdir", "bin")
            for f in filter(f -> occursin("hello_world", f), readdir(testbin_dir))
                f = joinpath(testbin_dir, f)
                @test strip(String(read(`$f`))) == "Hello, World!"
            end
        end
    end
end