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
        @test f in files
        @test f_link in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test f in collapsed_files
    end
end

@testset "Supported Platforms" begin
    all = supported_platforms()
    opt_out_specific = supported_platforms(exclude=[Linux(:x86_64, libc=:glibc)])
    # islin(x) = typeof(x) == Linux
    # opt_out_fx = supported_platforms(exclude=BinaryBuilder.islin)

    @test length(all) == length(opt_out_specific)+1
    @test !any(opt_out_specific .== [Linux(:x86_64, libc=:glibc)])
    # @test !any(opt_out_fx .== [Linux(:x86_64, libc=:glibc)])
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

@testset "environment and history saving" begin
    build_path = tempname()
    mkpath(build_path)
    prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform)
    @test_throws ErrorException build(ur, "foo", libfoo_products(prefix), "MARKER=1\nexit 1", platform, prefix)

    # Ensure that we get a metadir, and that our history and .env files are in there!
    metadir = joinpath(prefix.path, "..", "metadir")
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

@testset "GitHub releases build.jl reconstruction" begin
    # Download some random release that is relatively small
    product_hashes = product_hashes_from_github_release("staticfloat/OggBuilder", "v1.3.3-6")

    # Ground truth hashes for each product
    true_product_hashes = Dict(
        "arm-linux-gnueabihf"        => (
            "Ogg.v1.3.3.arm-linux-gnueabihf.tar.gz",
            "a70830decaee040793b5c6a8f8900ed81720aee51125a3aab22440b26e45997a"
        ),
        "x86_64-unknown-freebsd11.1" => (
            "Ogg.v1.3.3.x86_64-unknown-freebsd11.1.tar.gz",
            "a87e432f1e80880200b18decc33df87634129a2f9d06200cae89ad8ddde477b6"
        ),
        "i686-w64-mingw32"           => (
            "Ogg.v1.3.3.i686-w64-mingw32.tar.gz",
            "3f6f6f524137a178e9df7cb5ea5427de6694c2a44ef78f1491d22bd9c6c8a0e8"
        ),
        "powerpc64le-linux-gnu"      => (
            "Ogg.v1.3.3.powerpc64le-linux-gnu.tar.gz",
            "b133194a9527f087bbf942f77bf6a953cb8c277c98f609479bce976a31a5ba39"
        ),
        "x86_64-linux-gnu"           => (
            "Ogg.v1.3.3.x86_64-linux-gnu.tar.gz",
            "6ef771242553b96262d57b978358887a056034a3c630835c76062dca8b139ea6"
        ),
        "x86_64-apple-darwin14"      => (
            "Ogg.v1.3.3.x86_64-apple-darwin14.tar.gz",
            "077898aed79bbce121c5e3d5cd2741f50be1a7b5998943328eab5406249ac295"
        ),
        "x86_64-linux-musl"          => (
            "Ogg.v1.3.3.x86_64-linux-musl.tar.gz",
            "a7ff6bf9b28e1109fe26c4afb9c533f7df5cf04ace118aaae76c2fbb4c296b99"
        ),
        "aarch64-linux-gnu"          => (
            "Ogg.v1.3.3.aarch64-linux-gnu.tar.gz",
            "ce2329057df10e4f1755da696a5d5e597e1a9157a85992f143d03857f4af259c"
        ),
        "i686-linux-musl"            => (
            "Ogg.v1.3.3.i686-linux-musl.tar.gz",
            "d8fc3c201ea40feeb05bc84d7159286584427f54776e316ef537ff32347c4007"
        ),
        "x86_64-w64-mingw32"         => (
            "Ogg.v1.3.3.x86_64-w64-mingw32.tar.gz",
            "c6afdfb19d9b0d20b24a6802e49a1fbb08ddd6a2d1da7f14b68f8627fd55833a"
        ),
        "i686-linux-gnu"             => (
            "Ogg.v1.3.3.i686-linux-gnu.tar.gz",
            "1045d82da61ff9574d91f490a7be0b9e6ce17f6777b6e9e94c3c897cc53dd284"
        ),
    )

    @test length(product_hashes) == length(true_product_hashes)

    for target in keys(true_product_hashes)
        @test haskey(product_hashes, target)
        product_platform = extract_platform_key(product_hashes[target][1])
        true_product_platform = extract_platform_key(true_product_hashes[target][1])
        @test product_platform == true_product_platform
        @test product_hashes[target][2] == true_product_hashes[target][2]
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
