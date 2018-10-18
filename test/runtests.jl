using BinaryProvider
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

libfoo_products(prefix) = [
    LibraryProduct(prefix, "libfoo", :libfoo)
    ExecutableProduct(prefix, "fooifier", :fooifier)
]
libfoo_make_script = """
make clean
make install
"""
libfoo_cmake_script = raw"""
mkdir build
cd build
cmake -DCMAKE_INSTALL_PREFIX=${prefix} -DCMAKE_TOOLCHAIN_FILE=/opt/${target}/${target}.toolchain ..
make install
"""

# Ogg version
true_ogg_path = "https://github.com/staticfloat/OggBuilder/releases/download/v1.3.3-6"
true_ogg_hashes = Dict(
    "arm-linux-gnueabihf"        => (
        "Ogg.v1.3.3.arm-linux-gnueabihf.tar.gz",
        "a70830decaee040793b5c6a8f8900ed81720aee51125a3aab22440b26e45997a"
    ),
    "x86_64-unknown-freebsd11.1" => (
        "Ogg.v1.3.3.x86_64-unknown-freebsd11.1.tar.gz",
        "a87e432f1e80880200b18decc33df87634129a2f9d06200cae89ad8ddde477b6"
    ),
    "i686-w64-mingw32"           => (
        "Ogg.v1.3.3.i686-w64-mingw32.tar.gz",
        "3f6f6f524137a178e9df7cb5ea5427de6694c2a44ef78f1491d22bd9c6c8a0e8"
    ),
    "powerpc64le-linux-gnu"      => (
        "Ogg.v1.3.3.powerpc64le-linux-gnu.tar.gz",
        "b133194a9527f087bbf942f77bf6a953cb8c277c98f609479bce976a31a5ba39"
    ),
    "x86_64-linux-gnu"           => (
        "Ogg.v1.3.3.x86_64-linux-gnu.tar.gz",
        "6ef771242553b96262d57b978358887a056034a3c630835c76062dca8b139ea6"
    ),
    "x86_64-apple-darwin14"      => (
        "Ogg.v1.3.3.x86_64-apple-darwin14.tar.gz",
        "077898aed79bbce121c5e3d5cd2741f50be1a7b5998943328eab5406249ac295"
    ),
    "x86_64-linux-musl"          => (
        "Ogg.v1.3.3.x86_64-linux-musl.tar.gz",
        "a7ff6bf9b28e1109fe26c4afb9c533f7df5cf04ace118aaae76c2fbb4c296b99"
    ),
    "aarch64-linux-gnu"          => (
        "Ogg.v1.3.3.aarch64-linux-gnu.tar.gz",
        "ce2329057df10e4f1755da696a5d5e597e1a9157a85992f143d03857f4af259c"
    ),
    "i686-linux-musl"            => (
        "Ogg.v1.3.3.i686-linux-musl.tar.gz",
        "d8fc3c201ea40feeb05bc84d7159286584427f54776e316ef537ff32347c4007"
    ),
    "x86_64-w64-mingw32"         => (
        "Ogg.v1.3.3.x86_64-w64-mingw32.tar.gz",
        "c6afdfb19d9b0d20b24a6802e49a1fbb08ddd6a2d1da7f14b68f8627fd55833a"
    ),
    "i686-linux-gnu"             => (
        "Ogg.v1.3.3.i686-linux-gnu.tar.gz",
        "1045d82da61ff9574d91f490a7be0b9e6ce17f6777b6e9e94c3c897cc53dd284"
    ),
)
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
#include("basic.jl")
#include("building.jl")
#include("auditing.jl")
#include("wizard.jl")
include("gen_package.jl")

# These are broken for now
#include("package_tests.jl")
