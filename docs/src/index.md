# BinaryBuilder.jl

The purpose of the [`BinaryBuilder.jl`](https://github.com/JuliaPackaging/BinaryBuilder.jl) Julia package is to provide a system for compiling 3rd-party binary dependencies should work anywhere the [official Julia distribution](https://julialang.org/downloads) does.  In particular, using this package you will be able to compile your large pre-existing codebases of C, C++ and Fortran software into binaries that can be downloaded and loaded/run on a very wide range of machines.  As it is difficult (and often expensive) to natively compile software packages across the growing number of platforms that this package will need to support, we focus on Linux-hosted cross-compilers.  This package will therefore set up an environment to perform cross-compilation for all of the major platforms, and will do its best to make the compilation process as painless as possible.

Note that at this time, BinaryBuilder runs on Linux x86_64 systems only, with macOS support under active development, although it builds binaries for all major platforms.

## Project flow

`BinaryBuilder.jl` makes it easy to move from source code to packaged tarball.  In the end, what you hope to gain from using this package is a handful of compiled tarballs and a Julia snippet that uses [`BinaryProvider.jl`](https://github.com/JuliaPackaging/BinaryProvider.jl) to install the binaries.  An example of this is shown in [this file](https://github.com/JuliaPackaging/BinaryProvider.jl/blob/master/test/LibFoo.jl/deps/build.jl), where a mapping from the different platforms is established to various tarballs that have been built with this package, and according to the platform the user's Julia installation is running on, that package is downloaded and installed to a package-specific `Prefix`.

To get to that point, the source code for a project must be downloaded, it must be compiled for the various platforms, it must be packaged and hosted, at which point it may finally be downloaded and installed on user's machines.  Although it is technically possible to manually package software using `BinaryBuilder.jl`, this package is geared toward automation.  Most interaction with this package will revolve around methods to construct a `build_tarballs.jl` script for your source code that will download, build and package it into a nice tarball.  Note that while you can write your own build script from scratch, most users will want to use the Wizard to interactively generate this build script instead.

## Build scripts

A `BinaryBuilder.jl` build script (what is often referred to as a `build_tarballs.jl` file) looks something like this:

```julia
using BinaryBuilder

src_tarball = "<path to source tarball>"
src_hash    = "sha256 hash of the source tarball"
sources = [
    (src_tarball, src_hash),
]

script = raw"""
make
make install
"""

products(prefix) = [
    LibraryProduct(prefix, "libfoo", :libfoo),
    ExecutableProduct(prefix, "fooifier", :fooifier),
]

dependencies = []

# Build 'em!
autobuild(
    pwd(),
    "libfoo",
    supported_platforms(),
    sources,
    script,
    products,
    dependencies;
    verbose = true
)
```

This bare-bones snippet (an adapted form of the [`libfoo` test](../../test/build_libfoo_tarballs.jl) within this repository) first identifies the sources to download and compile (there can be multiple sources listed here), then lists the bash commands to actually build this particular project.  Next, the `products` are defined.  These represent the output of the build process, and are how `BinaryBuilder.jl` knows that its build has succeeded.  Finally, we pass this information off to `autobuild()`, which takes it all in and runs the builds, placing output tarballs into the `./products` directory.

The bash commands contained within `script` will be executed for each `platform` that is passed in, so if there are platform differences that need to be addressed in the build script, using `if` statements and the `$target` environment variable can be a powerful tool.  See the [OpenBLASBuilder build script](https://github.com/staticfloat/OpenBLASBuilder/blob/master/build_tarballs.jl) for an example showcasing this.

Once the `autobuild()` method completes, it will return a `product_hashes` object which can be used to print out a template `build.jl` file to download and install the generated tarballs.  This file is what will be used in Julia packages that need to use your built binaries, and is typically included within the tagged release uploads from a builder repository.  Here is an example release from the [IpoptBuilder repository](https://github.com/staticfloat/IpoptBuilder/releases/tag/v3.12.8-9), containing built tarballs as well as a `build.jl` that can be used within `Ipopt.jl`.

While constructing your own build script is certainly possible, `BinaryBuilder.jl` supports a more interactive method for building the binary dependencies and capturing the commands used to build it into a `build_tarballs.jl` file; the Wizard interface.

## Wizard interface

`BinaryBuilder.jl` contains a wizard interface that will walk you through constructing a `build_tarballs.jl` file.  To launch it, run `BinaryBuilder.run_wizard()`, and follow the instructions on-screen.