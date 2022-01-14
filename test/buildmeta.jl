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
        @test isempty(meta.dry_run)
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
            dry_run=Symbol[],
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
        @test isempty(meta.dry_run)
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
        @test isempty(meta.dry_run)
        @test isa(meta.json_output, IOStream)
        @test meta.json_output.name == "<file $(json_path)>"
        @test meta.deploy_target == "JuliaBinaryWrappers/Foo_jll.jl"
        @test meta.register_depot == "/tmp/depot"
    end

    # Helper function to generate a BuildConfig for us
    function mock(::Type{BuildConfig};
                  name = "Foo",
                  src_version = v"1.0.0",
                  sources = [ArchiveSource("url", "0"^40)],
                  script = "make install",
                  target = Platform("x86_64", "linux"),
                  dependencies = [Dependency("Bar_jll")])
        return BuildConfig(
            name,
            src_version,
            sources,
            script,
            target,
            dependencies,
        )
    end

    @testset "BuildConfig" begin
        # Create a `BuildConfig` manually, ensuring that all works
        config = mock(BuildConfig)
        @test config.src_name == "Foo"
        @test config.src_version == v"1.0.0"
        @test isempty(config.sources) == sources
        @test config.script == "make install"
        @test config.target == Platform("x86_64", "linux")
        # Note that this test relies upon the behavior of `get_concrete_platform()`
        @test config.concrete_target == Platform("x86_64", "linux"; libc="glibc", cxxstring_abi="cxx03", libgfortran_version=v"3")
        @test isempty(config.dependencies)


        # Create a `BuildMeta` with `dry_run` set to turn off builds, then call `build!()`
        meta = BuildMeta(;dry_run = [:build])
        build!(meta, config)
        @test haskey(meta.builds, config)
        @test meta.builds[config] === nothing


        # Create a simple build invocation, ensure that it creates a `BuildConfig` as we expect
        sources = [ArchiveSource("url", "0"^40)]
        deps = [Dependency("Bar_jll")]
        meta = BuildMeta(;dry_run = [:build])
        config = build!(
            meta,
            "Foo",
            v"1.0.0",
            sources,
            "make install",
            Platform("x86_64", "linux"),
            deps,
        )

        @test config.src_name == "Foo"
        @test config.src_version == v"1.0.0"
        @test config.sources == sources
        @test config.script == "make install"
        @test config.target == Platform("x86_64", "linux")
        @test config.dependencies == deps

        # Ensure this config is registered, but because we set `dry_run` to include `:build`, we don't get a build result.
        @test haskey(meta.builds, config)
        @test meta.builds[config] === nothing
    end

    # Function to create a fake BuildResult for us
    function mock(::Type{BuildResult};
                  config = mock(BuildConfig),
                  status = :successful,
                  prefix = mktempdir(),
                  logs = Dict{String,String}())
        return BuildResult(config, status, prefix, logs)
    end

    # Just test that we can construct a BuildResult.
    @testset "BuildResult" begin
        mktempdir() do prefix
            config = mock(BuildConfig)
            result = mock(BuildResult; config, prefix)

            @test result.config == config
            @test result.status == :successful
            @test result.prefix == prefix
            @test isempty(result.logs)
        end
    end
    
    function mock(::Type{ExtractConfig};
                  results=[mock(BuildResult)],
                  script="cp -a * \${prefix}",
                  products=[LibraryProduct("libfoo", :libfoo)])
        return ExtractConfig(
            results,
            script,
            products,
        )
    end

    @testset "ExtractConfig" begin
        # Create an `ExtractConfig` manually, ensuring that all works
        config = mock(ExtractConfig)
        @test isempty(config.builds)
        @test config.script == "cp -a * \${prefix}"
        @test isempty(config.products)

        # Create a `BuildMeta` with `dry_run` set to turn off extraction, then call `extract!()`
        meta = BuildMeta(;dry_run = [:extract])
        extract!(meta, config)
        @test haskey(meta.extractions, config)
        @test meta.extractions[config] === nothing

        # Create fake BuildResult, use it to call `extract!()`
        result = mock(BuildResult)
        meta = BuildMeta(;dry_run = [:extract])
        extract!(meta, )
    end
end
