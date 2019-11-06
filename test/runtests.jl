using Pkg
using BinaryBuilder
using BinaryBuilder: preferred_runner, exeext, dlext
using Pkg.PlatformEngines, Pkg.BinaryPlatforms
using Random, LibGit2, Libdl, Test, ObjectFile, SHA

# The platform we're running on
const platform = platform_key_abi()

# Helper function to try something and panic if it doesn't work
do_try(f) = try
    f()
catch e
    bt = catch_backtrace()
    Base.display_error(stderr, e, bt)

    # If a do_try fails, panic
    Test.@test false
end

# Helper function to run fortran code
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

# These are broken for now
#include("package_tests.jl")
