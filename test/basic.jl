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
    for p in [Linux(:i686), Windows(:i686), Linux(:armv7l)]
        @test BinaryBuilder.nbits(p) == 32
    end

    for p in [Linux(:x86_64), Windows(:x86_64), Linux(:aarch64),
              Linux(:powerpc64le), MacOS()]
        @test BinaryBuilder.nbits(p) == 64
    end

    for p in [Linux(:x86_64), MacOS(), Windows(:i686)]
        @test BinaryBuilder.proc_family(p) == :intel
    end
    for p in [Linux(:aarch64; libc=:musl), Linux(:armv7l)]
        @test BinaryBuilder.proc_family(p) == :arm
    end
    @test BinaryBuilder.proc_family(Linux(:powerpc64le)) == :power

    for p in [Linux(:aarch64), FreeBSD(:x86_64)]
        @test BinaryBuilder.dlext(p) == "so"
    end
    @test BinaryBuilder.dlext(MacOS()) == "dylib"
    @test BinaryBuilder.dlext(Windows(:i686)) == "dll"

    for p in [Linux(:x86_64), FreeBSD(:x86_64), Linux(:powerpc64le), MacOS()]
        @test BinaryBuilder.exeext(p) == ""
    end
    @test BinaryBuilder.exeext(Windows(:x86_64)) == ".exe"
    @test BinaryBuilder.exeext(Windows(:i686)) == ".exe"
end

# Are we using docker? If so, test that the docker runner works...
@testset "Runner utilities" begin
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

    if isa(preferred_runner(), BinaryBuilder.DockerRunner)
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
    end

    @testset "hello world" begin
        mktempdir() do dir
            ur = preferred_runner()(dir; platform=Linux(:x86_64; libc=:musl))
            iobuff = IOBuffer()
            @test run(ur, `/bin/bash -c "echo test"`, iobuff)
            seek(iobuff, 0)
            # Test that we get the output we expect (e.g. the second line is `test`)
            @test split(String(read(iobuff)), "\n")[2] == "test"
        end
    end
end

@testset "environment and history saving" begin
    mktempdir() do temp_path
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
    end
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

# Test that updating Yggdrasil works
Core.eval(BinaryBuilder, :(yggdrasil_updated = false))
io = IOBuffer()
BinaryBuilder.get_yggdrasil(io=io)
seek(io, 0)
@test match(r"Yggdrasil", String(read(io))) != nothing
