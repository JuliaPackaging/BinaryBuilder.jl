using Pkg
using BinaryBuilder
using BinaryBuilder: preferred_runner
using Random, LibGit2, Libdl, Test, ObjectFile, SHA

# The platform we're running on
const platform = platform_key_abi()

# On windows, the `.exe` extension is very important
const exe_ext = Sys.iswindows() ? ".exe" : ""

# We are going to build/install libfoo a lot, so here's our function to make sure the
# library is working properly
function check_foo(fooifier_path = "fooifier$(exe_ext)",
                   libfoo_path = "libfoo.$(Libdl.dlext)")
    # We know that foo(a, b) returns 2*a^2 - b
    result = 2*2.2^2 - 1.1

    # Test that we can invoke fooifier
    @test !success(`$fooifier_path`)
    @test success(`$fooifier_path 1.5 2.0`)
    @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

    # Test that we can dlopen() libfoo and invoke it directly
    libfoo = Libdl.dlopen_e(libfoo_path)
    @test libfoo != C_NULL
    foo = Libdl.dlsym_e(libfoo, :foo)
    @test foo != C_NULL
    @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
    Libdl.dlclose(libfoo)
end

libfoo_src_dir = joinpath(@__DIR__, "build_tests", "libfoo")
libfoo_products = [
    LibraryProduct("libfoo", :libfoo),
    ExecutableProduct("fooifier", :fooifier),
]

libfoo_make_script = raw"""
cd ${WORKSPACE}/srcdir/libfoo
make clean
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
ninja install
install_license ${WORKSPACE}/srcdir/libfoo/LICENSE.md
"""

# Helper function to try something and panic if it doesn't work
do_try(f) = try
    f()
catch e
    bt = catch_backtrace()
    Base.display_error(stderr, e, bt)

    # If a do_try fails, panic
    Test.@test false
end


# Run all our tests
include("basic.jl")
include("building.jl")
include("auditing.jl")
include("wizard.jl")

# These are broken for now
#include("package_tests.jl")
