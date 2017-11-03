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
    # Initialize our rootfs and sandbox blobs
    update_rootfs()
    update_sandbox_binary()
end
end # module
