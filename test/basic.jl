## Basic tests for simple utilities within BB
using BinaryBuilder, Test, Pkg, UUIDs
using BinaryBuilder: preferred_runner, resolve_jlls, CompilerShard, preferred_libgfortran_version, preferred_cxxstring_abi, gcc_version, available_gcc_builds, getversion, generate_compiler_wrappers!, getpkg, build_project_dict
using BinaryBuilder.BinaryBuilderBase
using BinaryBuilder.Wizard

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)
        d = joinpath(prefix, "bar")
        d_link = joinpath(prefix, "bar_link")
        mkpath(d)
        symlink(d, d_link)

        files = collect_files(prefix)
        @test length(files) == 3
        @test realpath(f) in files
        @test realpath(f_link) in files
        @test !(realpath(d) in files)
        @test !(realpath(d_link) in files)
        @test d_link in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test realpath(f) in collapsed_files

        files = collect_files(prefix, exclude_dirs = false)
        @test length(files) == 4
        @test realpath(f) in files
        @test realpath(f_link) in files
        @test realpath(d) in files
        @test realpath(d_link) in files

        files = collect_files(prefix, islink)
        @test length(files) == 2
        @test !(realpath(f) in files)
        @test f_link in files
        @test !(realpath(d) in files)
        @test d_link in files

        files = collect_files(prefix, islink, exclude_dirs = false)
        @test length(files) == 2
        @test !(realpath(f) in files)
        @test f_link in files
        @test !(realpath(d) in files)
        @test d_link in files
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

    @test sort([Windows(:x86_64), Linux(:i686, libc=:musl), Linux(:i686, libc=:glibc), MacOS(:x86_64)],
               by = triplet) ==
                   [Linux(:i686, libc=:glibc), Linux(:i686, libc=:musl), MacOS(:x86_64), Windows(:x86_64)]
end

@testset "AnyPlatform" begin
    # Test some AnyPlatform properties
    @test triplet(AnyPlatform()) == "any"
    @test Pkg.BinaryPlatforms.platform_name(AnyPlatform()) == "AnyPlatform"

    # In the build environment we want AnyPlatform to look like x86_64-linux-musl
    @test BinaryBuilderBase.get_concrete_platform(AnyPlatform(); compilers = [:c], preferred_gcc_version = v"7", preferred_llvm_version = v"9") ==
        BinaryBuilderBase.get_concrete_platform(Linux(:x86_64, libc=:musl); compilers = [:c], preferred_gcc_version = v"7", preferred_llvm_version = v"9")
    @test BinaryBuilder.choose_shards(AnyPlatform()) == BinaryBuilder.choose_shards(Linux(:x86_64, libc=:musl))
    @test BinaryBuilder.aatriplet(AnyPlatform()) == BinaryBuilder.aatriplet(Linux(:x86_64, libc=:musl))
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
        @test BinaryBuilderBase.dlext(p) == "so"
    end
    @test BinaryBuilderBase.dlext(MacOS()) == "dylib"
    @test BinaryBuilderBase.dlext(Windows(:i686)) == "dll"

    for p in [Linux(:x86_64), FreeBSD(:x86_64), Linux(:powerpc64le), MacOS()]
        @test BinaryBuilder.exeext(p) == ""
    end
    @test BinaryBuilder.exeext(Windows(:x86_64)) == ".exe"
    @test BinaryBuilder.exeext(Windows(:i686)) == ".exe"
end


@testset "Products" begin
    lp = LibraryProduct("libfakechroot", :libfakechroot, "lib/fakechroot")
    @test lp.libnames ==  ["libfakechroot"]
    @test lp.dir_paths == ["lib/fakechroot"]
    ep = ExecutableProduct("fooify", :fooify, "bin/foo_inc")
    @test ep.binnames ==  ["fooify"]

    @test_throws ErrorException LibraryProduct("sin", :sin)
    @test_throws ErrorException ExecutableProduct("convert", :convert)
    @test_throws ErrorException FileProduct("open", :open)

    # Test sorting of products....
    @test sort([LibraryProduct("libbar", :libbar), ExecutableProduct("foo", :foo), FrameworkProduct("buzz", :buzz)]) ==
        [FrameworkProduct("buzz", :buzz), ExecutableProduct("foo", :foo), LibraryProduct("libbar", :libbar)]
    # ...and products info
    p1 = LibraryProduct(["libchafa"], :libchafa, ) => Dict("soname" => "libchafa.so.0","path" => "lib/libchafa.so")
    p2 = ExecutableProduct(["chafa"], :chafa, ) => Dict("path" => "bin/chafa")
    products_info = Dict{Product,Any}(p1, p2)
    @test sort(products_info) == [p2, p1]
end

# Are we using docker? If so, test that the docker runner works...
@testset "Runner utilities" begin
    # Test that is_ecryptfs works for something we're certain isn't encrypted
    if isdir("/proc")
        isecfs = (false, "/proc/")
        @test BinaryBuilderBase.is_ecryptfs("/proc"; verbose=true) == isecfs
        @test BinaryBuilderBase.is_ecryptfs("/proc/"; verbose=true) == isecfs
        @test BinaryBuilderBase.is_ecryptfs("/proc/not_a_file"; verbose=true) == isecfs
    else
        @test BinaryBuilderBase.is_ecryptfs("/proc"; verbose=true) == (false, "/proc")
        @test BinaryBuilderBase.is_ecryptfs("/proc/"; verbose=true) == (false, "/proc/")
        @test BinaryBuilderBase.is_ecryptfs("/proc/not_a_file"; verbose=true) == (false, "/proc/not_a_file")
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
            FileSource[],
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
            Dependency[],
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
    @test Wizard.canonicalize_source_url(zmq_url) == zmq_url
    this_url = "https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    this_url_ans = "https://raw.githubusercontent.com/JuliaPackaging/BinaryBuilder.jl/1fee900486baedfce66ddb24872133ef36b9d899/test/wizard.jl"
    @test Wizard.canonicalize_file_url(this_url) == this_url_ans

    # Make sure normalization does what we expect
    @test Wizard.normalize_name("foo/libfoo.tar.gz") == "libfoo"
    @test Wizard.normalize_name("foo/libfoo-2.dll") == "libfoo"
    @test Wizard.normalize_name("libfoo") == "libfoo"
end

@testset "State serialization" begin
    state = Wizard.WizardState()
    state.step = :step34
    state.platforms = [Linux(:x86_64)]
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz"]
    state.source_files = [BinaryBuilder.SetupSource{ArchiveSource}("/tmp/source.tar.gz", bytes2hex(sha256("a")), "")]
    state.name = "libfoo"
    state.version = v"1.0.0"
    state.dependencies = [Dependency(PackageSpec(;name="Zlib_jll")),
                          Dependency(PackageSpec(;name="CompilerSupportLibraries_jll"))]
    state.history = "exit 1"

    io = Dict()
    Wizard.serialize(io, state)
    new_state = Wizard.unserialize(io)

    for field in fieldnames(Wizard.WizardState)
        @test getfield(state, field) == getfield(new_state, field)
    end
end

# Test that updating Yggdrasil works
@testset "Yggdrasil" begin
    Core.eval(Wizard, :(yggdrasil_updated = false))
    @test_logs (:info, r"Yggdrasil") Wizard.get_yggdrasil()
end

@testset "Tree symlinking" begin
    # Make sure symlink_tree works well with symlinks
    mktempdir() do tmpdir
        # Create fake source directory
        srcdir = joinpath(tmpdir, "src")
        mkdir(srcdir)

        mkdir(joinpath(srcdir, "dir"))
        open(joinpath(srcdir, "dir", "fileA"), "w") do io
            println(io, "fileA")
        end
        open(joinpath(srcdir, "dir", "fileB"), "w") do io
            println(io, "fileB")
        end
        symlink(joinpath("dir", "fileA"), joinpath(srcdir, "sym_fileA"))
        symlink("dir", joinpath(srcdir, "sym_dir"))

        dstdir = joinpath(tmpdir, "dst")

        # Set up a symlink tree inside of dstdir
        BinaryBuilderBase.symlink_tree(srcdir, dstdir)

        @test isdir(dstdir)
        @test isdir(joinpath(dstdir, "dir"))
        @test islink(joinpath(dstdir, "sym_dir"))
        @test islink(joinpath(dstdir, "sym_fileA"))
        @test islink(joinpath(dstdir, "dir", "fileA"))
        @test islink(joinpath(dstdir, "dir", "fileB"))

        @test readlink(joinpath(dstdir, "sym_dir")) == "dir"
        @test readlink(joinpath(dstdir, "sym_fileA")) == joinpath("dir", "fileA")

        @test String(read(joinpath(dstdir, "dir", "fileA"))) == "fileA\n"
        @test String(read(joinpath(dstdir, "dir", "fileB"))) == "fileB\n"
        @test String(read(joinpath(dstdir, "sym_fileA"))) == "fileA\n"
        @test String(read(joinpath(dstdir, "sym_dir", "fileB"))) == "fileB\n"

        # Create some files in `dstdir`, then unsymlink and see what happens:
        open(joinpath(dstdir, "dir", "fileC"), "w") do io
            println(io, "fileC")
        end
        symlink(joinpath("dir", "fileB"), joinpath(dstdir, "sym_fileB"))
        symlink(joinpath("dir", "fileC"), joinpath(dstdir, "sym_fileC"))
        symlink("dir", joinpath(dstdir, "sym_dir2"))

        BinaryBuilderBase.unsymlink_tree(srcdir, dstdir)

        @test isdir(dstdir)
        @test isdir(joinpath(dstdir, "dir"))
        @test !islink(joinpath(dstdir, "sym_dir"))
        @test !islink(joinpath(dstdir, "sym_fileA"))
        @test !isfile(joinpath(dstdir, "dir", "fileA"))
        @test !isfile(joinpath(dstdir, "dir", "fileB"))
        @test isfile(joinpath(dstdir, "dir", "fileC"))
        @test islink(joinpath(dstdir, "sym_dir2"))
        @test islink(joinpath(dstdir, "sym_fileB"))
        @test islink(joinpath(dstdir, "sym_fileC"))

        @test String(read(joinpath(dstdir, "dir", "fileC"))) == "fileC\n"
        @test String(read(joinpath(dstdir, "sym_fileC"))) == "fileC\n"
        @test_throws Base.IOError realpath(joinpath(dstdir, "sym_fileB"))
    end
end

@testset "resolve_jlls" begin
    # Deps given by name::String
    dependencies = ["OpenSSL_jll",]
    @test_logs (:warn, r"use Dependency instead") begin
        truefalse, resolved_deps = resolve_jlls(dependencies)
        @test truefalse
        @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
    end
    # Deps given by name::PackageSpec
    @test_logs (:warn, r"use Dependency instead") begin
        dependencies = [PackageSpec(name="OpenSSL_jll"),]
        truefalse, resolved_deps = resolve_jlls(dependencies)
        @test truefalse
        @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
    end
    # Deps given by (name,uuid)::PackageSpec
    dependencies = [Dependency(PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95")),]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
    # Deps given by combination of name::String, name::PackageSpec and (name,uuid)::PackageSpec
    dependencies = [
        Dependency("Zlib_jll"),
        Dependency(PackageSpec(name="Bzip2_jll")),
        Dependency(PackageSpec(name="OpenSSL_jll", uuid="458c3c95-2e84-50aa-8efc-19380b2a3a95")),
    ]
    truefalse, resolved_deps = resolve_jlls(dependencies)
    @test truefalse
    @test all(x->getpkg(x).uuid !== nothing, resolved_deps)
end

@testset "Compiler Shards" begin
    @test_throws ErrorException CompilerShard("GCCBootstrap", v"4", Linux(:x86_64), :invalid_archive_type)

    @testset "GCC ABI matching" begin
        # Preferred libgfortran version and C++ string ABI
        platform = FreeBSD(:x86_64)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"3"
        @test preferred_cxxstring_abi(platform, shard) == :cxx03
        shard = CompilerShard("GCCBootstrap", v"5.2.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"3"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("GCCBootstrap", v"7.1.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"4"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("GCCBootstrap", v"9.1.0", Linux(:x86_64, libc=:musl), :squashfs, target = platform)
        @test preferred_libgfortran_version(platform, shard) == v"5"
        @test preferred_cxxstring_abi(platform, shard) == :cxx11
        shard = CompilerShard("LLVMBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs)
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        platform = Linux(:x86_64, libc=:musl)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = MacOS(:x86_64))
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)
        shard = CompilerShard("GCCBootstrap", v"4.8.5", Linux(:x86_64, libc=:musl), :squashfs, target = Linux(:x86_64, libc=:glibc))
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        shard = CompilerShard("GCCBootstrap", v"1.2.3", Linux(:x86_64, libc=:musl), :squashfs, target = Windows(:x86_64))
        @test_throws ErrorException preferred_cxxstring_abi(platform, shard)
        @test_throws ErrorException preferred_libgfortran_version(platform, shard)

        # With no constraints, we should get them all back
        @test gcc_version(CompilerABI(), available_gcc_builds) == getversion.(available_gcc_builds)

        # libgfortran v3 and libstdcxx 22 restrict us to only v4.8, v5.2 and v6.1
        cabi = CompilerABI(;libgfortran_version=v"3", libstdcxx_version=v"3.4.22")
        @test gcc_version(cabi, available_gcc_builds) == [v"4.8.5", v"5.2.0", v"6.1.0"]

        # Adding `:cxx11` eliminates `v"4.X"`:
        cabi = CompilerABI(cabi; cxxstring_abi=:cxx11)
        @test gcc_version(cabi, available_gcc_builds) == [v"5.2.0", v"6.1.0"]

        # Just libgfortran v3 allows GCC 6 as well though
        cabi = CompilerABI(;libgfortran_version=v"3")
        @test gcc_version(cabi, available_gcc_builds) == [v"4.8.5", v"5.2.0", v"6.1.0"]

        # Test libgfortran version v4, then splitting on libstdcxx_version:
        cabi = CompilerABI(;libgfortran_version=v"4")
        @test gcc_version(cabi, available_gcc_builds) == [v"7.1.0"]
        cabi = CompilerABI(cabi; libstdcxx_version=v"3.4.23")
        @test gcc_version(cabi, available_gcc_builds) == [v"7.1.0"]
    end

    @testset "Compiler wrappers" begin
        platform = Linux(:x86_64, libc=:musl)
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path)
            # Make sure the C++ string ABI is not set
            @test !occursin("-D_GLIBCXX_USE_CXX11_ABI", read(joinpath(bin_path, "gcc"), String))
            # Make sure gfortran doesn't uses ccache when BinaryBuilder.use_ccache is true
            BinaryBuilderBase.use_ccache[] && @test !occursin("ccache", read(joinpath(bin_path, "gfortran"), String))
        end
        platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path)
            gcc = read(joinpath(bin_path, "gcc"), String)
            # Make sure the C++ string ABI is set as expected
            @test occursin("-D_GLIBCXX_USE_CXX11_ABI=0", gcc)
            # Make sure the unsafe flags check is there
            @test occursin("You used one or more of the unsafe flags", gcc)
        end
        platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path, allow_unsafe_flags = true)
            gcc = read(joinpath(bin_path, "gcc"), String)
            # Make sure the C++ string ABI is set as expected
            @test occursin("-D_GLIBCXX_USE_CXX11_ABI=1", gcc)
            # Make sure the unsafe flags check is not there in this case
            @test !occursin("You used one or more of the unsafe flags", gcc)
        end
        platform = FreeBSD(:x86_64)
        mktempdir() do bin_path
            generate_compiler_wrappers!(platform; bin_path = bin_path, compilers = [:c, :rust, :go])
            clang = read(joinpath(bin_path, "clang"), String)
            # Check link flags
            @test occursin("-L/opt/$(triplet(platform))/$(triplet(platform))/lib", clang)
            @test occursin("fuse-ld=$(triplet(platform))", clang)
            # Other compilers
            @test occursin("GOOS=\"freebsd\"", read(joinpath(bin_path, "go"), String))
            @test occursin("--target=x86_64-unknown-freebsd", read(joinpath(bin_path, "rustc"), String))
        end
        platform      = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        host_platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx11))
        mktempdir() do bin_path
            @test_throws ErrorException generate_compiler_wrappers!(platform; bin_path = bin_path, host_platform = host_platform)
        end
        platform      = Linux(:x86_64, libc=:musl)
        host_platform = Linux(:x86_64, libc=:musl, compiler_abi=CompilerABI(cxxstring_abi=:cxx03))
        mktempdir() do bin_path
            @test_throws ErrorException generate_compiler_wrappers!(platform; bin_path = bin_path, host_platform = host_platform)
        end
    end
end

@testset "Registration utils" begin
    name = "CGAL"
    version = v"1"
    dependencies = [Dependency("boost_jll"), Dependency("GMP_jll"),
                    Dependency("MPFR_jll"), Dependency("Zlib_jll")]
    dict = build_project_dict(name, version, dependencies)
    @test dict["name"] == "$(name)_jll"
    @test dict["version"] == "1.0.0"
    @test dict["uuid"] == "8fcd9439-76b0-55f4-a525-bad0597c05d8"
    @test dict["compat"] == Dict{String,Any}("julia" => "1.0")
    @test all(in.(
        (
            "Pkg"       => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
            "Libdl"     => "8f399da3-3557-5675-b5ff-fb832c97cbdb",
            "GMP_jll"   => "781609d7-10c4-51f6-84f2-b8444358ff6d",
            "MPFR_jll"  => "3a97d323-0669-5f0c-9066-3539efd106a3",
            "Zlib_jll"  => "83775a58-1f1d-513f-b197-d71354ab007a",
            "boost_jll" => "28df3c45-c428-5900-9ff8-a3135698ca75",
        ), Ref(dict["deps"])))
    project = Pkg.Types.Project(dict)
    @test project.name == "$(name)_jll"
    @test project.uuid == UUID("8fcd9439-76b0-55f4-a525-bad0597c05d8")
    # Make sure that a `BuildDependency` can't make it to the list of
    # dependencies of the new JLL package
    @test_throws MethodError build_project_dict(name, version, [BuildDependency("Foo_jll")])

    version = v"1.6.8"
    next_version = BinaryBuilder.get_next_wrapper_version("Xorg_libX11", version)
    @test next_version.major == version.major
    @test next_version.minor == version.minor
    @test next_version.patch == version.patch

    # Ensure passing compat bounds works
    dependencies = [
        Dependency(PackageSpec(name="libLLVM_jll", version=v"9")),
    ]
    dict = build_project_dict("Clang", v"9.0.1+2", dependencies)
    @test dict["compat"]["julia"] == "1.0"
    @test dict["compat"]["libLLVM_jll"] == "=9.0.0"
    
    dependencies = [
        Dependency(PackageSpec(name="libLLVM_jll", version="8.3-10")),
    ]
    dict = build_project_dict("Clang", v"9.0.1+2", dependencies)
    @test dict["compat"]["julia"] == "1.0"
    @test dict["compat"]["libLLVM_jll"] == "8.3-10"
end

@testset "Dlopen flags" begin
    lp = LibraryProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL, :RTLD_NOLOAD])
    @test lp.dlopen_flags == [:RTLD_GLOBAL, :RTLD_NOLOAD]
    fp = FrameworkProduct("libfoo2", :libfoo2; dlopen_flags=[:RTLD_GLOBAL, :RTLD_NOLOAD])
    @test fp.libraryproduct.dlopen_flags == [:RTLD_GLOBAL, :RTLD_NOLOAD]
    for p in (lp, fp)
        flag_str = BinaryBuilderBase.dlopen_flags_str(p)
        @test flag_str == ", RTLD_GLOBAL | RTLD_NOLOAD"
        @test Libdl.eval(Meta.parse(flag_str[3:end])) == (Libdl.RTLD_NOLOAD | Libdl.RTLD_GLOBAL)
    end
end
