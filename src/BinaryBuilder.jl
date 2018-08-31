# You know it's getting real when this is uncommented
# __precompile__()

module BinaryBuilder
using Compat, Compat.Libdl, Compat.LibGit2, Compat.Random
using Reexport
using ObjectFile
using Nullables
using GitHub

@reexport using BinaryProvider
export url_hash

include("compat.jl")
include("Auditor.jl")
include("Runner.jl")
include("RootFS.jl")
include("UserNSRunner.jl")
include("QemuRunner.jl")
include("Dependency.jl")
include("AutoBuild.jl")
include("Wizard.jl")

# This is a global github authentication token that is set the first time
# we authenticate and then reused
const _github_auth = Ref{GitHub.Authorization}()

function github_auth()
    if !isassigned(_github_auth)
        # If the user is feeding us a GITHUB_TOKEN token, use it!
        if length(get(ENV, "GITHUB_TOKEN", "")) == 40
            _github_auth[] = GitHub.authenticate(ENV["GITHUB_TOKEN"])
        else
            _github_auth[] = GitHub.AnonymousAuth()
        end
    end
    return _github_auth[]
end

# These globals store important information such as where we're downloading
# the rootfs to, and where we're unpacking it.  These constants are initialized
# by `__init__()` to allow for environment variable overrides from the user.
downloads_cache = ""
rootfs_cache = ""
shards_cache = ""
qemu_cache = ""
automatic_apple = false
use_squashfs = false
allow_ecryptfs = false
use_ccache = false
ccache_override = ""
sandbox_override = ""

function __init__()
    global downloads_cache, rootfs_cache, shards_cache, runner_override
    global qemu_cache, use_squashfs, automatic_apple, allow_ecryptfs
    global use_ccache, ccache_override, sandbox_override

    # If the user has overridden our rootfs tar location, reflect that here:
    def_dl_cache = joinpath(dirname(@__FILE__), "..", "deps", "downloads")
    downloads_cache = get(ENV, "BINARYBUILDER_DOWNLOADS_CACHE", def_dl_cache)
    downloads_cache = abspath(downloads_cache)

    # If the user has overridden our rootfs unpack location, reflect that here:
    def_rootfs_cache = joinpath(dirname(@__FILE__),  "..", "deps", "root")
    rootfs_cache = get(ENV, "BINARYBUILDER_ROOTFS_DIR", def_rootfs_cache)
    rootfs_cache = abspath(rootfs_cache)

    # If the user has overridden our shards unpack location, reflect that here:
    def_shards_cache = joinpath(dirname(@__FILE__),  "..", "deps", "shards")
    shards_cache = get(ENV, "BINARYBUILDER_SHARDS_DIR", def_shards_cache)
    shards_cache = abspath(shards_cache)

    # If the user has overridden our qemu unpack location, reflect that here:
    def_qemu_cache = joinpath(dirname(@__FILE__), "..", "deps", "qemu")
    qemu_cache = get(ENV, "BINARYBUILDER_QEMU_DIR", def_qemu_cache)
    qemu_cache = abspath(qemu_cache)

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
    end

    # If the user has signalled that they really want us to automatically
    # accept apple EULAs, do that.
    if get(ENV, "BINARYBUILDER_AUTOMATIC_APPLE", "") == "true"
        automatic_apple = true
    end

    # If the user has overridden our runner selection algorithms, honor that
    runner_override = lowercase(get(ENV, "BINARYBUILDER_RUNNER", ""))
    if !(runner_override in ["", "userns", "qemu", "privileged"])
        Compat.@warn("Invalid runner value $runner_override, ignoring...")
        runner_override = ""
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

    # If the user has asked to use a particular `sandbox` executable, use it!
    sandbox_override = get(ENV, "BINARYBUILDER_SANDBOX_PATH", "")
    if !isempty(sandbox_override) && !isfile(sandbox_override)
        Compat.@warn("Invalid sandbox path $sandbox_override, ignoring...")
        sandbox_override = ""
    end

    # If the user asked for the ccache cache to be placed somewhere specific
    ccache_override = get(ENV, "BINARYBUILDER_CCACHE_PATH", "")
    if !isempty(ccache_override) && !isdir(ccache_override)
        Compat.@warn("Invalid ccache directory $ccache_override, ignoring...")
        ccache_override = ""
    end
end

"""
    versioninfo()

Helper function to print out some debugging information
"""
function versioninfo()
    Compat.@info("Julia versioninfo(): ")
    Base.versioninfo()

    # Get BinaryBuilder.jl's git sha
    repo = LibGit2.GitRepo(Pkg.dir("BinaryBuilder"))
    gitsha = hex(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
    Compat.@info("BinaryBuilder.jl version: $(gitsha)")
    @static if Compat.Sys.isunix()
        Compat.@info("Kernel version: $(readchomp(`uname -r`))")
    end

    # Dump if some important directories are encrypted:
    @static if Compat.Sys.islinux()
        print_enc(n, path) = begin
            is_encrypted, mountpoint = is_ecryptfs(path)
            if is_encrypted
                Compat.@info("$n is encrypted on mountpoint $mountpoint")
            else
                Compat.@info("$n is NOT encrypted on mountpoint $mountpoint")
            end
        end

        print_enc("pkg dir", dirname(@__FILE__))
        print_enc("rootfs dir", rootfs_dir())
        print_enc("shards dir", shards_dir())
    end

    # Dump any relevant environment variables:
    Compat.@info("Relevant envionment variables:")
    env_var_suffixes = [
        "AUTOMATIC_APPLE",
        "USE_SQUASHFS",
        "DOWNLOADS_CACHE",
        "ROOTFS_DIR",
        "SHARDS_DIR",
        "QEMU_DIR",
        "RUNNER",
        "ALLOW_ECRYPTFS",
        "USE_CCACHE",
    ]
    for e in env_var_suffixes
        envvar = "BINARYBUILDER_$(e)"
        if haskey(ENV, envvar)
            Compat.@info("  $(envvar): \"$(ENV[envvar])\"")
        end
    end

    # Print out the preferred runner stuff here:
    Compat.@info("Preferred runner: $(preferred_runner())")

    # Try to run 'echo julia' in Linux x86_64 environment
    Compat.@info("Trying to run `echo hello julia` within a Linux x86_64 environment...")

    runner = preferred_runner()(
        pwd();
        cwd="/workspace/",
        platform=Linux(:x86_64),
        verbose=true
    )
    run_interactive(runner, `/bin/bash -c "echo hello julia"`)

    # If we use ccache, dump the ccache stats
    if use_ccache
        Compat.@info("ccache stats:")
        runner = preferred_runner()(
            pwd();
            cwd="/workspace/",
            platform=Linux(:x86_64),
        )
        run_interactive(runner, `/usr/local/bin/ccache -s`)
    end
end

function url_hash(url::AbstractString)
    path = download(url)
    open(path) do io
        bytes2hex(BinaryProvider.sha256(io))
    end
end

end # module
