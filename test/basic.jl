## Basic tests for simple utilities within BB

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)

        files = collect_files(prefix)
        @test length(files) == 2
        @test realpath(f) in files
        @test realpath(f_link) in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test realpath(f) in collapsed_files
    end
end

@testset "Supported Platforms" begin
    all = supported_platforms()
    opt_out_specific = supported_platforms(exclude=[Linux(:x86_64, libc=:glibc)])
    islin(x) = typeof(x) == Linux
    opt_out_fx = supported_platforms(exclude=islin)

    @test length(all) == length(opt_out_specific)+1
    @test any(opt_out_specific .== [Linux(:i686 , libc=:glibc)])
    @test !any(opt_out_fx .== [Linux(:i686 , libc=:glibc)])
end

@testset "Target properties" begin
    for t in ["i686-linux-gnu", "i686-w64-mingw32", "arm-linux-gnueabihf"]
        @test BinaryBuilder.target_nbits(t) == "32"
    end

    for t in ["x86_64-linux-gnu", "x86_64-w64-mingw32", "aarch64-linux-gnu",
              "powerpc64le-linux-gnu", "x86_64-apple-darwin14"]
        @test BinaryBuilder.target_nbits(t) == "64"
    end

    for t in ["x86_64-linux-gnu", "x86_64-apple-darwin14", "i686-w64-mingw32"]
        @test BinaryBuilder.target_proc_family(t) == "intel"
    end
    for t in ["aarch64-linux-gnu", "arm-linux-gnueabihf"]
        @test BinaryBuilder.target_proc_family(t) == "arm"
    end
    @test BinaryBuilder.target_proc_family("powerpc64le-linux-gnu") == "power"

    for t in ["aarch64-linux-gnu", "x86_64-unknown-freebsd11.1"]
        @test BinaryBuilder.target_dlext(t) == "so"
    end
    @test BinaryBuilder.target_dlext("x86_64-apple-darwin14") == "dylib"
    @test BinaryBuilder.target_dlext("i686-w64-mingw32") == "dll"
end

@testset "UserNS utilities" begin
    # Test that is_ecryptfs works for something we're certain isn't encrypted
    if isdir("/proc")
        isecfs = (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == isecfs
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == isecfs
    else
        @test BinaryBuilder.is_ecryptfs("/proc"; verbose=true) == (false, "/proc")
        @test BinaryBuilder.is_ecryptfs("/proc/"; verbose=true) == (false, "/proc/")
        @test BinaryBuilder.is_ecryptfs("/proc/not_a_file"; verbose=true) == (false, "/proc/not_a_file")
    end
end

# Is docker available?  If so, test that the docker runner works...
if Sys.which("docker") != nothing
    @testset "Docker Runner" begin
        @testset "Docker image importing" begin
            # First, delete the docker image, in case it already existed
            BinaryBuilder.delete_docker_image()

            # Next, import it and ensure that doesn't throw
            rootfs = first(BinaryBuilder.choose_shards(platform))
            mktempdir() do dir
                @test BinaryBuilder.import_docker_image(rootfs, dir; verbose=true) === nothing
            end

            # Test that deleting the docker image suceeds, now that we know
            # it exists
            @test BinaryBuilder.delete_docker_image()
        end

        @testset "Docker hello world" begin
            mktempdir() do dir
                dr = BinaryBuilder.DockerRunner(dir; platform=Linux(:x86_64; libc=:musl))
                iobuff = IOBuffer()
                @test run(dr, `/bin/bash -c "echo test"`, iobuff)
                seek(iobuff, 0)
                # Test that we get the output we expect (e.g. the second line is `test`)
                @test split(String(read(iobuff)), "\n")[2] == "test"
            end
        end
    end
end


@testset "environment and history saving" begin
    mktempdir() do temp_path; cd(temp_path) do
        @test_throws ErrorException autobuild(
            temp_path,
            "this_will_fail",
            v"1.0.0",
            # No sources to speak of
            [],
            # Simple script that just sets an environment variable
            """
            MARKER=1
            exit 1
            """,
            # Build for this platform
            [platform],
            # No products
            Product[],
            # No depenedencies
            [],
        )

        # build_path is the nonce'd build directory
        build_path = joinpath(temp_path, "build", triplet(platform))
        build_path = joinpath(build_path, first(readdir(build_path)))

        # Ensure that we get a metadir, and that our history and .env files are in there!
        metadir = joinpath(build_path, "metadir")
        @test isdir(metadir)

        hist_file = joinpath(metadir, ".bash_history")
        env_file = joinpath(metadir, ".env")
        @test isfile(hist_file)
        @test isfile(env_file)

        # Test that exit 1 is in .bash_history
        @test occursin("\nexit 1\n", read(open(hist_file), String))

        # Test that MARKER=1 is in .env:
        @test occursin("\nMARKER=1\n", read(open(env_file), String))

        # Delete the build path
        rm(build_path, recursive = true)
    end; end
end

@testset "Wizard Utilities" begin
    # Make sure canonicalization does what we expect
    zmq_url = "https://github.com/zeromq/zeromq3-x/releases/download/v3.2.5/zeromq-3.2.5.tar.gz"
    @test BinaryBuilder.canonicalize_source_url(zmq_url) == zmq_url
    this_url = "https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    this_url_ans = "https://raw.githubusercontent.com/JuliaPackaging/BinaryBuilder.jl/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    @test BinaryBuilder.canonicalize_file_url(this_url) == this_url_ans

    # Make sure normalization does what we expect
    @test BinaryBuilder.normalize_name("foo/libfoo.tar.gz") == "libfoo"
    @test BinaryBuilder.normalize_name("foo/libfoo-2.dll") == "libfoo"
    @test BinaryBuilder.normalize_name("libfoo") == "libfoo"
end
