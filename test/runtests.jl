using Pkg
using BinaryBuilder
using BinaryBuilder: preferred_runner, exeext, dlext
using Pkg.PlatformEngines, Pkg.BinaryPlatforms
using Random, LibGit2, Libdl, Test, ObjectFile, SHA

# The platform we're running on
const platform = platform_key_abi()
const build_tests_dir = joinpath(@__DIR__, "build_tests")

# Helper function to run fortran code with the path to libgfortran/libquadmath
# embedded in the appropriate environment variables (JLL packages we love you so)
csl_path = dirname(first(filter(x -> occursin("libgfortran", x), Libdl.dllist())))
LIBPATH_var, envsep = if Sys.iswindows()
    ("PATH", ";")
elseif Sys.isapple()
    ("DYLD_LIBRARY_PATH", ":")
else
    ("LD_LIBRARY_PATH", ":")
end
function with_libgfortran(f::Function)
    libpath_list = [csl_path split(get(ENV, LIBPATH_var, ""), envsep)]
    libpath = join(filter(x -> !isempty(x), libpath_list), envsep)
    withenv(f, LIBPATH_var => libpath)
end

# Run all our tests
include("basic.jl")
include("building.jl")
include("auditing.jl")
include("wizard.jl")
include("declarative.jl")
