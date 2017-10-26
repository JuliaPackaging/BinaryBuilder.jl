# You know it's getting real when this is uncommented
# __precompile__()

module BinaryBuilder
using Compat
using Reexport
@reexport using BinaryProvider

include("Auditor.jl")
include("DockerRunner.jl")
include("UserNSRunner.jl")
include("Dependency.jl")
include("AutoBuild.jl")
include("Wizard.jl")

export shortname, autobuild, run_wizard

"""
    shortname(p::Platform)

Get a convenient symbol representation of the given platform.

# Examples
```jldoctest
julia> shortname(Linux(:i686))
:linux32

julia> shortname(MacOS())
:osx64
```
"""
function shortname(p::Linux)
    a = arch(p)
    if a === :x86_64 || a === :i686
        return Symbol("linux", wordsize(p))
    else
        return Symbol("linux", a)
    end
end
shortname(p::Windows) = Symbol("win", wordsize(p))
shortname(p::MacOS) = :osx64

end # module
