# You know it's getting real when this is uncommented
# __precompile__()

module BinaryBuilder
using Compat
using Reexport
@reexport using BinaryProvider

include("Auditor.jl")
include("Runner.jl")
include("RootFS.jl")
include("UserNSRunner.jl")
include("QemuRunner.jl")
include("Dependency.jl")
include("AutoBuild.jl")
include("Wizard.jl")

function __init__()
    global downloads_cache, rootfs_cache, use_squashfs, automatic_apple, shards_cache

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
end

"""
    versioninfo()

Helper function to print out some debugging information
"""
function versioninfo()
    info("Julia versioninfo(): ")
    Base.versioninfo()

    # Get BinaryBuilder.jl's git sha
    repo = LibGit2.GitRepo(Pkg.dir("BinaryBuilder"))
    gitsha = hex(LibGit2.GitHash(LibGit2.GitCommit(repo, "HEAD")))
    info("BinaryBuilder.jl version: $(gitsha)")
    info("Preferred runner: $(preferred_runner())")

    # Dump any relevant environment variables:
    info("Relevant envionment variables:")
    env_var_suffixes = [
        "DOWNLOADS_CACHE",
        "ROOTFS_DIR",
        "SHARDS_DIR",
        "USE_SQUASHFS",
        "AUTOMATIC_APPLE",
    ]
    for e in env_var_suffixes
        envvar = "BINARYBUILDER_$(e)"
        if haskey(ENV, envvar)
            info("  $(envvar): \"$(ENV[envvar])\"")
        end
    end

    # Try to run 'echo julia' in Linux x86_64 environment
    info("Trying to run `echo julia` within a Linux x86_64 environment...")

    runner = preferred_runner()(
        pwd();
        cwd="/workspace/",
        platform=Linux(:x86_64),
        verbose=true
    )
    run_interactive(runner, `/bin/bash -c "echo test"`)
end

end # module
