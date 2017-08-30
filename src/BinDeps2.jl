# You know it's getting real when this is uncommented
# __precompile__()

module BinDeps2
using Compat
using Reexport
@reexport using BinaryProvider

include("Auditor.jl")
include("DockerRunner.jl")
include("Dependency.jl")

end # module