# You know it's getting real when this is uncommented
# __precompile__()

module BinDeps2

# Building packages from source, installing them into a prefix,
# auditing them to ensure they were built correctly, and 
# Build from source into a prefix


include("Prefix.jl")
include("OutputCollector.jl")
include("Auditor.jl")
include("DownloadEngine.jl")
include("BuildResult.jl")
include("BuildStep.jl")
include("Dependency.jl")

function __init__()
    # Find the right download engine for this platform
    global download, global_prefix
    download = probe_download_engine()

    # Initialize our global_prefix
    global_prefix = Prefix(joinpath(dirname(@__FILE__), "../", "global_prefix"))
    activate(global_prefix)

    # If we're on a julia that's too old, then fixup the color mappings
    if !haskey(Base.text_colors, :default)
        Base.text_colors[:default] = Base.color_normal
    end
end



end # module


# much test lol
using BinDeps2

#BinDeps2.Dependency(BinDeps2.global_prefix, )