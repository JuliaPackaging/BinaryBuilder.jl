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

@testset "environment and history saving" begin
    mktempdir() do temp_path
        # This is a litmus test, to catch any errors before we do a `@test_throws`
        @test_logs (:error, r"^Unable to find valid license file") match_mode=:any autobuild(
            temp_path,
            "this_will_pass",
            v"1.0.0",
            # No sources to speak of
            FileSource[],
            # Just exit with code 0
            """
            exit 0
            """,
            # Build for this platform
            [platform],
            # No products
            Product[],
            # No depenedencies
            Dependency[],
        )

        @test_throws ErrorException autobuild(
            temp_path,
            "this_will_fail",
            v"1.0.0",
            FileSource[],
            # Simple script that just sets an environment variable
            """
            MARKER=1
            exit 1
            """,
            [platform],
            Product[],
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

    # with_gitcreds
    local creds_outer = nothing
    Wizard.with_gitcreds("user", "password") do creds
        @test creds isa LibGit2.UserPasswordCredential
        @test hasproperty(creds, :user)
        @test hasproperty(creds, :pass)
        creds_outer = creds # assign to parent scope, so that we can check on it later
        @test creds.user == "user"
        @test String(read(creds.pass)) == "password"
        @test !Base.isshredded(creds.pass)
    end
    @test creds_outer isa LibGit2.UserPasswordCredential
    @test creds_outer.user == ""
    @test Base.isshredded(creds_outer.pass)
    @test eof(creds_outer.pass)
    # in case it throws:
    creds_outer = nothing
    @test_throws ErrorException Wizard.with_gitcreds("user", "password") do creds
        creds_outer = creds
        error("...")
    end
    @test creds_outer isa LibGit2.UserPasswordCredential
    @test creds_outer.user == ""
    @test Base.isshredded(creds_outer.pass)
    @test eof(creds_outer.pass)
end

@testset "State serialization" begin
    state = Wizard.WizardState()
    state.step = :step34
    state.platforms = [Platform("x86_64", "linux")]
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

@testset "Registration utils" begin
    name = "CGAL"
    version = v"1"
    dependencies = [Dependency("boost_jll"), Dependency("GMP_jll"),
                    Dependency("MPFR_jll"), Dependency("Zlib_jll")]
    dict = build_project_dict(name, version, dependencies)
    @test dict["name"] == "$(name)_jll"
    @test dict["version"] == "1.0.0"
    @test dict["uuid"] == "8fcd9439-76b0-55f4-a525-bad0597c05d8"
    @test dict["compat"] == Dict{String,Any}("julia" => "1.0", "JLLWrappers" => "1.1.0")
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

    # Ensure passing a Julia dependency bound works
    dict = build_project_dict(name, version, dependencies, "1.4")
    @test dict["compat"] == Dict{String,Any}("julia" => "1.4", "JLLWrappers" => "1.1.0")

    dict = build_project_dict(name, version, dependencies, "~1.4")
    @test dict["compat"] == Dict{String,Any}("julia" => "~1.4", "JLLWrappers" => "1.1.0")

    @test_throws ErrorException build_project_dict(name, version, dependencies, "nonsense")

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
