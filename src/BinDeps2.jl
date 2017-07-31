# You know it's getting real when this is uncommented
# __precompile__()

module BinDeps2
using Compat

include("Prefix.jl")
include("OutputCollector.jl")
include("Auditor.jl")
include("PlatformEngines.jl")
include("BuildResult.jl")
include("DockerRunner.jl")
include("Dependency.jl")

function __init__()
    global global_prefix

    # Initialize our global_prefix
    global_prefix = Prefix(joinpath(dirname(@__FILE__), "../", "global_prefix"))
    activate(global_prefix)

    # Find the right download/compression engines for this platform
    probe_platform_engines!()

    # If we're on a julia that's too old, then fixup the color mappings
    if !haskey(Base.text_colors, :default)
        Base.text_colors[:default] = Base.color_normal
    end
end

end # module