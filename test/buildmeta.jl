using Test, BinaryBuilder, Pkg
using BinaryBuilder: parse_build_tarballs_args
using Base.BinaryPlatforms

@testset "BuildMeta" begin
    @testset "parse_build_tarballs_args" begin
        # Ensure that we get very simple defaults for no args
        parsed_kwargs = parse_build_tarballs_args(String[])
        @test !parsed_kwargs[:verbose]
        @test !haskey(parsed_kwargs, :debug)
        @test !haskey(parsed_kwargs, :json_output)
        @test parsed_kwargs[:deploy_target] == "local"
        @test !haskey(parsed_kwargs, :register_depot)
        @test !haskey(parsed_kwargs, :target_list)

        # Next, turn on options that have defaults
        parsed_kwargs = parse_build_tarballs_args(String[
            "--verbose",
            "--debug",
            "--meta-json",
            "--deploy",
            "--register",
        ])
        @test parsed_kwargs[:verbose]
        @test parsed_kwargs[:debug] == "error"
        @test parsed_kwargs[:json_output] == Base.stdout
        @test parsed_kwargs[:deploy_target] == "local"
        @test parsed_kwargs[:register_depot] == Pkg.depots1()
        @test !haskey(parsed_kwargs, :target_list)

        # Next, supply arguments to them all
        parsed_kwargs = parse_build_tarballs_args(String[
            "--debug=begin",
            "--meta-json=meta.json",
            "--deploy=JuliaBinaryWrappers/Foo_jll.jl",
            "--register=/tmp/bb_depot",
            "x86_64-apple-darwin14,aarch64-linux-musl,i686-linux-gnu-libgfortran3-cxx11",
        ])
        @test parsed_kwargs[:debug] == "begin"
        @test parsed_kwargs[:json_output] == "meta.json"
        @test parsed_kwargs[:deploy_target] == "JuliaBinaryWrappers/Foo_jll.jl"
        @test parsed_kwargs[:register_depot] == "/tmp/bb_depot"
        @test parsed_kwargs[:target_list] == [
            Platform("x86_64", "macos"; os_version=v"14"),
            Platform("aarch64", "linux"; libc="musl"),
            Platform("i686", "linux"; libgfortran_version=v"3", cxxstring_abi="cxx11"),
        ]

        # And now trigger some errors
        @test_throws ArgumentError parse_build_tarballs_args(String["--debug=fail"])
        @test_throws ArgumentError parse_build_tarballs_args(String["--verbose", "x86_64-apple-darwin14", "aarch64-linux-gnu"])
    end

    @testset "BuildMeta" begin
        # First, test default options
        meta = BuildMeta()
        @test isempty(meta.builds)
        @test isempty(meta.packages)
        @test isempty(meta.target_list)
        @test !meta.verbose
        @test meta.debug === nothing
        @test meta.json_output === nothing
        @test meta.deploy_target == "local"
        @test meta.register_depot === nothing

        # Now, provide parameters for all sorts of stuff
        meta = BuildMeta(;
            target_list=[
                Platform("x86_64", "linux"),
                Platform("i686", "windows"),
            ],
            verbose=true,
            debug="end",
            json_output=Base.stdout,
            deploy_target="JuliaBinaryWrappers/Foo_jll.jl",
            register_depot="/tmp/depot",
        )
        @test isempty(meta.builds)
        @test isempty(meta.packages)
        @test length(meta.target_list) == 2
        @test os(meta.target_list[1]) == "linux"
        @test os(meta.target_list[2]) == "windows"
        @test meta.verbose
        @test meta.debug == "end"
        @test meta.json_output == Base.stdout
        @test meta.deploy_target == "JuliaBinaryWrappers/Foo_jll.jl"
        @test meta.register_depot == "/tmp/depot"

        # Next, test some errors
        @test_throws ArgumentError BuildMeta(;debug="foo")
        @test_throws ArgumentError BuildMeta(;deploy_target="not_local")
        @test_throws ArgumentError BuildMeta(;register_depot="/tmp/depot")

        # Next, test end-to-end parsing of ARGS-style options
        json_path=mktemp()[1]
        meta = BuildMeta([
            "--verbose",
            "--debug=begin",
            "--meta-json=$(json_path)",
            "--deploy=JuliaBinaryWrappers/Foo_jll.jl",
            "--register=/tmp/depot",
            "x86_64-linux-gnu,x86_64-linux-musl,i686-linux-gnu"
        ])
        @test isempty(meta.builds)
        @test isempty(meta.packages)
        @test length(meta.target_list) == 3
        @test all(os.(meta.target_list) .== "linux")
        @test meta.verbose
        @test meta.debug == "begin"
        @test isa(meta.json_output, IOStream)
        @test meta.json_output.name == "<file $(json_path)>"
        @test meta.deploy_target == "JuliaBinaryWrappers/Foo_jll.jl"
        @test meta.register_depot == "/tmp/depot"
    end

    @testset "BuildConfig" begin
        


    end
end
