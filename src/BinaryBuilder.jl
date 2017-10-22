# You know it's getting real when this is uncommented
# __precompile__()

module BinaryBuilder
using Compat
using Reexport
@reexport using BinaryProvider

include("Auditor.jl")
include("DockerRunner.jl")
include("Dependency.jl")

export shortname

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
shortname(p::Linux) = Symbol("linux", wordsize(p))
shortname(p::Windows) = Symbol("win", wordsize(p))
shortname(p::MacOS) = :osx64

end # module
