using Pkg
using BinaryBuilder, BinaryBuilder.BinaryBuilderBase
using BinaryBuilder.BinaryBuilderBase: preferred_runner, platform_dlext, platform_exeext
using Base.BinaryPlatforms
using Random, LibGit2, Test, ObjectFile, SHA
import Libdl

# The platform we're running on
const platform = HostPlatform()
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

## Tests involing building packages and whatnot
libfoo_products = [
    LibraryProduct("libfoo", :libfoo),
    ExecutableProduct("fooifier", :fooifier),
]

libfoo_make_script = raw"""
cd ${WORKSPACE}/srcdir/libfoo
make install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

libfoo_cmake_script = raw"""
mkdir ${WORKSPACE}/srcdir/libfoo/build && cd ${WORKSPACE}/srcdir/libfoo/build
cmake -DCMAKE_INSTALL_PREFIX=${prefix} -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} ..
make install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

libfoo_meson_script = raw"""
mkdir ${WORKSPACE}/srcdir/libfoo/build && cd ${WORKSPACE}/srcdir/libfoo/build
meson .. -Dprefix=${prefix} --cross-file="${MESON_TARGET_TOOLCHAIN}"
meson install

# grumble grumble meson!  Why do you go to all the trouble to build it properly
# in `build`, then screw it up when you `install` it?!  Silly willy.
if [[ ${target} == *apple* ]]; then
    install_name_tool ${prefix}/bin/fooifier -change ${prefix}/lib/libfoo.0.dylib @rpath/libfoo.0.dylib
fi
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

libfoo_autotools_script = raw"""
cd ${WORKSPACE}/srcdir/libfoo
autoreconf -fiv
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target} --disable-static
make install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

# Run all our tests
# include("basic.jl")
# include("building.jl")
# include("auditing.jl")
include("jll.jl")
include("wizard.jl")
include("declarative.jl")
