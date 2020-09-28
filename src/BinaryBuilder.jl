module BinaryBuilder
using Libdl, LibGit2, Random, JSON
using BinaryBuilderBase
using ObjectFile
using GitHub
import InteractiveUtils
using Pkg, Base.BinaryPlatforms, Pkg.Artifacts
using ghr_jll

# Re-export useful stuff from Pkg:
export HostPlatform, platform_dlext, valid_dl_path, arch, libc,
       libgfortran_version, libstdcxx_version, cxxstring_abi, detect_libgfortran_version,
       detect_libstdcxx_version, detect_cxxstring_abi, call_abi, wordsize, triplet,
       select_platform, platforms_match, AbstractPlatform, Platform
# Re-export some compat wrappers:
using Pkg.BinaryPlatforms: Linux, MacOS, Windows, FreeBSD
export Linux, MacOS, Windows, FreeBSD
# BinaryBuilderBase/src/Prefix.jl
export Prefix, bindir, libdirs, includedir, logdir, activate, deactivate,
       isinstalled, install, uninstall, list_tarball_files, verify, temp_prefix
# BinaryBuilderBase/src/Rootfs.jl
export supported_platforms, expand_gfortran_versions, expand_cxxstring_abis
# BinaryBuilderBase/src/Platforms.jl
export AnyPlatform
# BinaryBuilderBase/src/Products.jl
export Product, LibraryProduct, FileProduct, ExecutableProduct, FrameworkProduct, satisfied,
       locate, write_deps_file, variable_name
# BinaryBuilderBase/src/Dependency.jl
export Dependency, BuildDependency
# BinaryBuilderBase/src/Sources.jl
export ArchiveSource, FileSource, GitSource, DirectorySource
# Auditor.jl
export audit, collect_files, collapse_symlinks

# Import some useful stuff from BinaryBuilderBase
import BinaryBuilderBase: runshell

include("Auditor.jl")
include("Wizard.jl")

using OutputCollectors, BinaryBuilderBase, .Auditor, .Wizard

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
        try
            # Settle for the treehash otherwise
            env = Pkg.Types.Context().env
            bb_uuid = Pkg.Types.UUID("12aac903-9f7c-5d81-afc2-d9565ea332ae")
            treehash = bytes2hex(env.manifest[bb_uuid].tree_hash.bytes)
            return VersionNumber("$(version)-tree-$(treehash[1:10])")
        catch
            # Something went so wrong, we can't get any of that.
            return VersionNumber(version)
        end
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
        platform=Platform("x86_64", "linux"),
        verbose=true
    )
    run_interactive(runner, `/bin/bash -c "echo hello julia"`)

    # If we use ccache, dump the ccache stats
    if BinaryBuilderBase.use_ccache
        @info("ccache stats:")
        runner = preferred_runner()(
            pwd();
            cwd="/workspace/",
            platform=Platform("x86_64", "linux"),
        )
        run_interactive(runner, `/usr/bin/ccache -s`)
    end
    return nothing
end


# Precompilation ahoy!
# include("../deps/SnoopCompile/precompile/precompile_BinaryBuilder.jl")
# _precompile_()

end # module
