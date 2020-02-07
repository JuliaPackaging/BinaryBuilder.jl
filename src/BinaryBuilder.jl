module BinaryBuilder
using Libdl, LibGit2, Random, Sockets, Base64, JSON
using ObjectFile
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

include("compat.jl")
include("OutputCollector.jl")
include("Sources.jl")
include("Dependencies.jl")
include("Prefix.jl")
include("Products.jl")
include("Auditor.jl")
include("Runner.jl")
include("Rootfs.jl")
include("squashfs_utils.jl")
include("UserNSRunner.jl")
include("DockerRunner.jl")
include("AutoBuild.jl")
include("Wizard.jl")
include("Declarative.jl")

# This is the location that all binary builder-related files are stored under.
# downloads, unpacked .tar.gz shards, mounted shards, ccache cache, etc....
function storage_dir(args::AbstractString...)
    global storage_cache
    dir = joinpath(storage_cache, args...)
    mkpath(dirname(dir))
    return dir
end
ccache_dir() = storage_dir("ccache")

# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
storage_cache = ""
automatic_apple = false
use_squashfs = false
allow_ecryptfs = false
use_ccache = false
bootstrap_list = Symbol[]

function __init__()
    global runner_override, use_squashfs, automatic_apple, allow_ecryptfs
    global use_ccache, storage_cache

    # Pkg does this lazily; do it explicitly here.
    Pkg.PlatformEngines.probe_platform_engines!()

    # Allow the user to override the default value for `storage_dir`
    storage_cache = get(ENV, "BINARYBUILDER_STORAGE_DIR",
                        abspath(joinpath(@__DIR__, "..", "deps")))

    # If the user has signalled that they really want us to automatically
    # accept apple EULAs, do that.
    if get(ENV, "BINARYBUILDER_AUTOMATIC_APPLE", "") == "true"
        automatic_apple = true
    end

    # If the user has overridden our runner selection algorithms, honor that
    runner_override = lowercase(get(ENV, "BINARYBUILDER_RUNNER", ""))
    if runner_override == "unprivileged"
        runner_override = "userns"
    end
    if !(runner_override in ["", "userns", "privileged", "docker"])
        @warn("Invalid runner value $runner_override, ignoring...")
        runner_override = ""
    end

    # If the user has asked for squashfs mounting instead of tarball mounting,
    # use that here.  Note that on Travis, we default to using squashfs, unless
    # BINARYBUILDER_USE_SQUASHFS is set to "false", which overrides this
    # default. If we are not on Travis, we default to using tarballs and not
    # squashfs images as using them requires `sudo` access.
    if get(ENV, "BINARYBUILDER_USE_SQUASHFS", "") == "false"
        use_squashfs = false
    elseif get(ENV, "BINARYBUILDER_USE_SQUASHFS", "") == "true"
        use_squashfs = true
    else
        # If it hasn't been specified, but we're on Travis, default to "on"
        if get(ENV, "TRAVIS", "") == "true"
            use_squashfs = true
        end

        # If it hasn't been specified but we're going to use the docker runner,
        # then set `use_squashfs` to `true` here.
        if preferred_runner() == DockerRunner
            # Conversely, if we're dock'ing it up, don't use it.
            use_squashfs = false
        elseif runner_override == "privileged"
            # If we're forcing a privileged runner, go ahead and default to squashfs
            use_squashfs = true
        end
    end

    # If the user has signified that they want to allow mounting of ecryptfs
    # paths, then let them do so at their own peril.
    if get(ENV, "BINARYBUILDER_ALLOW_ECRYPTFS", "") == "true"
        allow_ecryptfs = true
    end

    # If the user has enabled `ccache` support, use it!
    if get(ENV, "BINARYBUILDER_USE_CCACHE", "false") == "true"
        use_ccache = true
    end
end

function get_bb_version()
    # Get BinaryBuilder.jl's version and git sha
    version = Pkg.TOML.parsefile(joinpath(@__DIR__, "..", "Project.toml"))["version"]
    try
        repo = LibGit2.GitRepo(dirname(@__DIR__))
        gitsha = string(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
        return VersionNumber("$(version)-$(gitsha)")
    catch
        return VersionNumber(version)
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
    @info("Relevant envionment variables:")
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
    if use_ccache
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
