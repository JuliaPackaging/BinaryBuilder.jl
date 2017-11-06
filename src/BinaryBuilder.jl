# You know it's getting real when this is uncommented
# __precompile__()

module BinaryBuilder
using Compat
using Reexport
@reexport using BinaryProvider

include("Auditor.jl")
include("Runner.jl")
include("UserNSRunner.jl")
include("Dependency.jl")
include("AutoBuild.jl")
include("Wizard.jl")

function __init__()
    global rootfs_tar, rootfs

    # If the user has overridden our rootfs tar location, reflect that here:
    def_dl_cache = joinpath(dirname(@__FILE__), "..", "deps", "downloads")
    downloads_cache = get(ENV, "BINARYBUILDER_DOWNLOADS_CACHE", def_dl_cache)
    rootfs_tar = joinpath(downloads_cache, "rootfs.tar.gz")

    # If the user has overridden our rootfs unpack location, reflect that here:
    def_rootfs_dir = joinpath(dirname(@__FILE__), "..", "deps", "root")
    rootfs = get(ENV, "BINARYBUILDER_ROOTFS_DIR", def_rootfs_dir)

    # Initialize our rootfs and sandbox blobs
    update_rootfs()
    update_sandbox_binary()
end
end # module
