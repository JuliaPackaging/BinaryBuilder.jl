module BinaryBuilder
using Libdl, LibGit2, Random, Base64, JSON
using ObjectFile # TODO can this be removed from top-level?
using GitHub
import InteractiveUtils
using Pkg, Pkg.BinaryPlatforms, Pkg.PlatformEngines, Pkg.Artifacts
using ghr_jll

# Re-export useful stuff from Pkg:
export platform_key_abi, platform_dlext, valid_dl_path, arch, libc, compiler_abi,
       libgfortran_version, libstdcxx_version, cxxstring_abi, parse_dl_name_version,
       detect_libgfortran_version, detect_libstdcxx_version, detect_cxxstring_abi,
       call_abi, wordsize, triplet, select_platform, platforms_match,
       CompilerABI, Platform, UnknownPlatform, Linux, MacOS, Windows, FreeBSD

module BinaryBuilderBase

using JSON, Pkg, Pkg.BinaryPlatforms, Pkg.PlatformEngines, Pkg.Artifacts, OutputCollectors, Random, Libdl

export AbstractSource, AbstractDependency, SetupSource, PatchSource,
    resolve_jlls, coerce_dependency, coerce_source, Runner,
    generate_compiler_wrappers!, preferred_runner, CompilerShard, UserNSRunner,
    DockerRunner, choose_shards, exeext, preferred_libgfortran_version,
    preferred_cxxstring_abi, gcc_version, available_gcc_builds, getversion,
    getpkg, replace_libgfortran_version, replace_cxxstring_abi, aatriplet,
    nbits, proc_family, storage_dir, extract_kwargs, extract_fields,
    download_source, setup_workspace, setup_dependencies, update_registry,
    getname, cleanup_dependencies, compress_dir, run_interactive, sourcify,
    dependencify, with_logfile, get_concrete_platform

include("compat.jl")

include("Sources.jl")
include("Dependencies.jl")
include("Prefix.jl")
include("Products.jl")
include("Platforms.jl")

include("Runner.jl")
include("Rootfs.jl")
include("squashfs_utils.jl")
include("UserNSRunner.jl")
include("DockerRunner.jl")

## Functions previously in the wizard

with_logfile(f::Function, prefix::Prefix, name::String) = with_logfile(f, joinpath(logdir(prefix), name))
function with_logfile(f::Function, logfile::String)
    mkpath(dirname(logfile))

    # If it's already a file, remove it, as it is probably an incorrect symlink
    if isfile(logfile)
        rm(logfile; force=true)
    end
    open(logfile, "w") do io
        f(io)
    end
end

# We only want to update the registry once per run
registry_updated = false
function update_registry(ctx = Pkg.Types.Context())
    global registry_updated
    if !registry_updated
        Pkg.Registry.update(ctx, [
            Pkg.Types.RegistrySpec(uuid = "23338594-aafe-5451-b93e-139f81909106"),
        ])
        registry_updated = true
    end
end

##

## Functions previously in AutoBuild.jl

"""
    get_concrete_platform(platform::Platform, shards::Vector{CompilerShard})

Return the concrete platform for the given `platform` based on the GCC compiler
ABI in the `shards`.
"""
function get_concrete_platform(platform::Platform, shards::Vector{CompilerShard})
    # We want to get dependencies that have exactly the same GCC ABI as the
    # chosen compiler, otherwise we risk, e.g., to build in an environment
    # with libgfortran3 a dependency built with libgfortran5.
    # `concrete_platform` is needed only to setup the dependencies and the
    # runner.  We _don't_ want the platform passed to `audit()` or
    # `package()` to be more specific than it is.
    concrete_platform = platform
    gccboostrap_shard_idx = findfirst(x -> x.name == "GCCBootstrap" &&
                                      x.target.arch == platform.arch &&
                                      x.target.libc == platform.libc,
                                      shards)
    if !isnothing(gccboostrap_shard_idx)
        libgfortran_version = preferred_libgfortran_version(platform, shards[gccboostrap_shard_idx])
        cxxstring_abi = preferred_cxxstring_abi(platform, shards[gccboostrap_shard_idx])
        concrete_platform = replace_cxxstring_abi(replace_libgfortran_version(platform, libgfortran_version), cxxstring_abi)
    end
    return concrete_platform
end

"""
    get_concrete_platform(platform::Platform;
                          preferred_gcc_version = nothing,
                          preferred_llvm_version = nothing,
                          compilers = nothing)

Return the concrete platform for the given `platform` based on the GCC compiler
ABI.  The set of shards is chosen by the keyword arguments (see [`choose_shards`](@ref)).
"""
function get_concrete_platform(platform::Platform;
                               preferred_gcc_version = nothing,
                               preferred_llvm_version = nothing,
                               compilers = nothing)
    shards = choose_shards(platform;
                           preferred_gcc_version = preferred_gcc_version,
                           preferred_llvm_version = preferred_llvm_version,
                           compilers = compilers)
    return get_concrete_platform(platform, shards)
end

# XXX: we want the AnyPlatform to look like `x86_64-linux-musl`,
get_concrete_platform(::AnyPlatform, shards::Vector{CompilerShard}) =
    get_concrete_platform(Linux(:x86_64, libc=:musl), shards)

##

end # module BinaryBuilderBase

module Auditor

using ..BinaryBuilderBase
using Pkg, Pkg.BinaryPlatforms
using ObjectFile

include("Auditor.jl")

end # module Auditor

module Wizard

using ..BinaryBuilderBase, OutputCollectors, ..Auditor
using Random
using GitHub, LibGit2, Pkg, Sockets, ObjectFile
import SHA: sha256

include("Wizard.jl")

end # module Wizard

using OutputCollectors, .BinaryBuilderBase, .Auditor, .Wizard
## Reexport the exports

# Prefix.jl
export Prefix, bindir, libdirs, includedir, logdir, activate, deactivate,
       isinstalled,
       install, uninstall, list_tarball_files, verify, temp_prefix
# Rootfs.jl
export supported_platforms, expand_gfortran_versions, expand_cxxstring_abis
# Platforms.jl
export AnyPlatform
# Products.jl
export Product, LibraryProduct, FileProduct, ExecutableProduct, FrameworkProduct, satisfied,
       locate, write_deps_file, variable_name
# Dependency.jl
export Dependency, BuildDependency
# Sources.jl
export ArchiveSource, FileSource, GitSource, DirectorySource
# Auditor.jl
export audit, collect_files, collapse_symlinks

##

include("AutoBuild.jl")
include("Declarative.jl")
include("Logging.jl")

function __init__()
    # If we're running on Azure, enable azure logging:
    if !isempty(get(ENV, "AZP_TOKEN", ""))
        enable_azure_logging()
    end
end

function get_bb_version()
    # Get BinaryBuilder.jl's version and git sha
    version = Pkg.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"]
    try
        # get the gitsha if we can
        repo = LibGit2.GitRepo(dirname(@__DIR__))
        gitsha = string(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
        return VersionNumber("$(version)-git-$(gitsha[1:10])")
    catch
        # Settle for the treehash otherwise
        env = Pkg.Types.Context().env
        bb_uuid = Pkg.Types.UUID("12aac903-9f7c-5d81-afc2-d9565ea332ae")
        treehash = bytes2hex(env.manifest[bb_uuid].tree_hash.bytes)
        return VersionNumber("$(version)-tree-$(treehash[1:10])")
    end
end

"""
    versioninfo()

Helper function to print out some debugging information
"""
function versioninfo()
    @info("Julia versioninfo(): ")
    InteractiveUtils.versioninfo()

    @info("BinaryBuilder.jl version: $(get_bb_version())")

    @static if Sys.isunix()
        @info("Kernel version: $(readchomp(`uname -r`))")
    end

    # Dump if some important directories are encrypted:
    @static if Sys.islinux()
        print_enc(n, path) = begin
            is_encrypted, mountpoint = is_ecryptfs(path)
            if is_encrypted
                @info("$n is encrypted on mountpoint $mountpoint")
            else
                @info("$n is NOT encrypted on mountpoint $mountpoint")
            end
        end

        print_enc("pkg dir", dirname(@__FILE__))
        print_enc("storage dir", storage_dir())
    end

    # Dump any relevant environment variables:
    @info("Relevant environment variables:")
    env_var_suffixes = [
        "AUTOMATIC_APPLE",
        "USE_SQUASHFS",
        "STORAGE_DIR",
        "RUNNER",
        "ALLOW_ECRYPTFS",
        "USE_CCACHE",
    ]
    for e in env_var_suffixes
        envvar = "BINARYBUILDER_$(e)"
        if haskey(ENV, envvar)
            @info("  $(envvar): \"$(ENV[envvar])\"")
        end
    end

    # Print out the preferred runner stuff here:
    @info("Preferred runner: $(preferred_runner())")

    # Try to run 'echo julia' in Linux x86_64 environment
    @info("Trying to run `echo hello julia` within a Linux x86_64 environment...")

    runner = preferred_runner()(
        pwd();
        cwd="/workspace/",
        platform=Linux(:x86_64),
        verbose=true
    )
    run_interactive(runner, `/bin/bash -c "echo hello julia"`)

    # If we use ccache, dump the ccache stats
    if BinaryBuilderBase.use_ccache[]
        @info("ccache stats:")
        runner = preferred_runner()(
            pwd();
            cwd="/workspace/",
            platform=Linux(:x86_64),
        )
        run_interactive(runner, `/usr/bin/ccache -s`)
    end
    return nothing
end


# Precompilation ahoy!
include("../deps/SnoopCompile/precompile/precompile_BinaryBuilder.jl")
_precompile_()

end # module
