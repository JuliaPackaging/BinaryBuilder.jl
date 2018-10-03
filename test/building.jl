## Tests involing building packages and whatnot

@testset "Builder Packaging" begin
    # Gotta set this guy up beforehand
    tarball_path = nothing
    tarball_hash = nothing

	# Test building with both `make` and `cmake`
    for script in (libfoo_make_script, libfoo_cmake_script)
        product_storage = tempname()
        mkpath(product_storage)

		begin
			build_path = tempname()
			mkpath(build_path)
			prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform)
			cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
				run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)
				@test build(ur, "foo", libfoo_products(prefix), script, platform, prefix)
			end

			# Next, package it up as a .tar.gz file
            tarball_path, tarball_hash = package(prefix, joinpath(product_storage, "libfoo"), v"1.0.0"; verbose=true)
			@test isfile(tarball_path)

			# Delete the build path
			rm(build_path, recursive = true)
		end

		# Test that we can inspect the contents of the tarball
		contents = list_tarball_files(tarball_path)
		@test "bin/fooifier" in contents
		@test "lib/libfoo.$(Libdl.dlext)" in contents

		# Install it within a new Prefix
		temp_prefix() do prefix
			# Install the thing
			@test install(tarball_path, tarball_hash; prefix=prefix, verbose=true)

			# Ensure we can use it
			fooifier_path = joinpath(bindir(prefix), "fooifier")
			libfoo_path = joinpath(libdir(prefix), "libfoo.$(Libdl.dlext)")
			check_foo(fooifier_path, libfoo_path)
		end

        rm(product_storage; recursive=true, force=true)
    end
end

if lowercase(get(ENV, "BINARYBUILDER_FULL_SHARD_TEST", "false") ) == "true"
    @info("Beginning full shard test...")
    # Perform a sanity test on each and every shard.
    @testset "Shard sanity tests" begin
        for shard_platform in expand_gcc_versions(supported_platforms())
            @info(" --> $(triplet(shard_platform))")
            build_path = tempname()
            mkpath(build_path)

            # build with make
            prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], shard_platform)
            cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
                run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

                # Build libfoo, warn if we fail
                @test build(ur, "foo", libfoo_products(prefix), libfoo_make_script, shard_platform, prefix)
            end
            rm(build_path, recursive = true)

            # build again with cmake
            mkpath(build_path)
            prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], shard_platform)
			cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
                run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

                # Build libfoo, warn if we fail
                @test build(ur, "foo", libfoo_products(prefix), libfoo_cmake_script, shard_platform, prefix)
            end
            rm(build_path, recursive = true)
        end
    end
end

# Testset to make sure we can build_tarballs() from a local directory
@testset "build_tarballs() local directory based" begin
    build_path = tempname()
    local_dir_path = joinpath(build_path, "libfoo")
    mkpath(local_dir_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll just copy it
        # into a new directory and use build_tarball's ability to auto-package
        # local directories to do all the heavy lifting.
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $local_dir_path`)

        build_tarballs(
            [], # fake ARGS
            "libfoo",
            v"1.0.0",
            [local_dir_path],
            libfoo_make_script,
            [Linux(:x86_64, :glibc)],
            libfoo_products,
            [], # no dependencies
        )

        # Make sure that worked
        @test isfile("products/libfoo.v1.0.0.x86_64-linux-gnu.tar.gz")
        @test isfile("products/build_libfoo.v1.0.0.jl")
    end
end

# Testset to make sure we can build_tarballs() from a git repository
@testset "build_tarballs() Git-Based" begin
    # Skip this testset on Travis, because its libgit2 is broken right now.
    if get(ENV, "TRAVIS", "") == "true"
        return
    end

    build_path = tempname()
    git_path = joinpath(build_path, "libfoo.git")
    mkpath(git_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll create a fake
        # git repo for it here, then build from that.
        repo = LibGit2.init(git_path)
        LibGit2.commit(repo, "Initial empty commit")
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $git_path/`)
        for file in ["fooifier.cpp", "libfoo.c", "Makefile"]
            LibGit2.add!(repo, file)
        end
        commit = LibGit2.commit(repo, "Add libfoo files")

        # Now build that git repository for Linux x86_64
        sources = [
            git_path =>
            LibGit2.string(LibGit2.GitHash(commit)),
        ]

        build_tarballs(
            [], # fake ARGS
            "libfoo",
            v"1.0.0",
            sources,
            "cd libfoo\n$libfoo_make_script",
            [Linux(:x86_64, :glibc)],
            libfoo_products,
            [], # no dependencies
        )

        # Make sure that worked
        @test isfile("products/libfoo.v1.0.0.x86_64-linux-gnu.tar.gz")
        @test isfile("products/build_libfoo.v1.0.0.jl")
    end

    rm(build_path; force=true, recursive=true)
end

@testset "build_tarballs() --only-buildjl" begin
    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        # Clone down OggBuilder.jl
        repo = LibGit2.clone("https://github.com/staticfloat/OggBuilder", ".")

        # Check out a known-good tag
        LibGit2.checkout!(repo, string(LibGit2.GitHash(LibGit2.GitCommit(repo, "v1.3.3-6"))))

        # Reconstruct binaries!  We don't want it to pick up BinaryBuilder.jl information from CI,
        # so wipe out those environment variables through withenv:
        blacklist = ["CI_REPO_OWNER", "CI_REPO_NAME", "TRAVIS_REPO_SLUG", "TRAVIS_TAG", "CI_COMMIT_TAG"]
        withenv((envvar => nothing for envvar in blacklist)...) do
            m = Module(:__anon__)
            Core.eval(m, quote
                ARGS = ["--only-buildjl"]
            end)
            Base.include(m, joinpath(build_path, "build_tarballs.jl"))
        end

        # Read in `products/build.jl` to get download_info
        m = Module(:__anon__)
        download_info = Core.eval(m, quote
            using BinaryProvider
            # Override BinaryProvider functionality so that it doesn't actually install anything
            function install(args...; kwargs...); end
            function write_deps_file(args...; kwargs...); end
        end)
        # Include build.jl file to extract download_info
        Base.include(m, joinpath(build_path, "products", "build_Ogg.v1.3.3.jl"))
        download_info = Core.eval(m, :(download_info))

        # Test that we get the info right about some of these platforms
        bin_prefix = "https://github.com/staticfloat/OggBuilder/releases/download/v1.3.3-6"
        @test download_info[Linux(:x86_64)] == (
            "$bin_prefix/Ogg.v1.3.3.x86_64-linux-gnu.tar.gz",
            "6ef771242553b96262d57b978358887a056034a3c630835c76062dca8b139ea6",
        )
        @test download_info[Windows(:i686)] == (
            "$bin_prefix/Ogg.v1.3.3.i686-w64-mingw32.tar.gz",
            "3f6f6f524137a178e9df7cb5ea5427de6694c2a44ef78f1491d22bd9c6c8a0e8",
        )
    end
end

