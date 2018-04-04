# BinaryBuilder.jl

The purpose of the [`BinaryBuilder.jl`](https://github.com/JuliaPackaging/BinaryBuilder.jl) Julia package is to provide a system for compiling 3rd-party binary dependencies should work anywhere the [official Julia distribution](https://julialang.org/downloads) does.  In particular, using this package you will be able to compile your large pre-existing codebases of C, C++ and Fortran software into binaries that can be downloaded and loaded/run on a very wide range of machines.  As it is difficult (and often expensive) to natively compile software packages across the growing number of platforms that this package will need to support, we focus on Linux-hosted cross-compilers.  This package will therefore set up an environment to perform cross-compilation for all of the major platforms, and will do its best to make the compilation process as painless as possible.

Note that at this time, BinaryBuilder runs on Linux x86_64 systems only, with macOS support under active development, although it builds binaries for all major platforms.

## Project flow

Suppose that you have a Julia package `Foo.jl` for which you want to build binary dependencies.  With BinaryBuilder, you will create a GitHub repository `FooBuilder` that contains (at minimum) a `build_tarballs.jl` Julia script to build the libraries and other binaries needed by `Foo.jl` and a `.travis.yml` file to configure Travis CI to automatically run `build_tarballs.jl` and upload ("deploy") the resulting binaries ("build artifacts") to a release in the `FooBuilder` repository.  Also deployed to the release will be a [`build.jl` file](https://github.com/JuliaPackaging/BinaryProvider.jl/blob/master/test/LibFoo.jl/deps/build.jl) that you can use in `Foo.jl` (with the `BinaryProvider` package) to download these binaries as needed.   Much of this is can be done for you automatically by the the [`run_wizard`](@ref) function, though that wizard currently only runs on Linux (and soon macOS) with supported hardware.

The `build_tarballs.jl` file is a Julia script of the form `using BinaryBuilder; build_tarballs(ARGS, "Foo", sources, script, platforms, products, dependencies)`.  See below for a detailed description of the arguments, but essentially you provide: a list of `sources` to download (source code tarballs or git repositories, for example) and any `dependencies` required to build, a bash `script` to build and install your code, a list of `platforms` to build on, and a list of build `products` (e.g. libraries) to save and upload.  This is the script that will be ultimately run on a Travis CI Linux server — once you get things working, you don't need any special hardware or software of your own, because the Travis servers provide everything that is needed.

You must have a Travis CI account and [enable Travis](https://docs.travis-ci.com/user/getting-started/) for your `FooBuilder` repository on Github.   This will allow Travis to automatically run your script whenever changes are pushed to the repository.  The `.travis.yml` file describes what Travis should run, and for BinaryBuilder this file should have a particular form that is automatically generated for you by the `run_wizard` function, and can also be created by the `setup_travis` function. Alternatively, you can copy it from one of the provided examples, changing a couple of lines for the name of the repo and the OAuth token.

In particular, Travis [uploads the build products to a GitHub release](https://docs.travis-ci.com/user/deployment/releases/) whenever you push a new tag or create a new release in your `FooBuilder` repository. To do this, Travis needs to authenticate itself to the Github server, and it does this using an encrypted OAuth token stored in your `.travis.yml` file.   This token is created for you automatically by the `run_wizard` or `setup_travis` functions, and it can also be created manually via `travis setup releases` using the [`travis` command-line program](https://github.com/travis-ci/travis.rb#installation).

Once these files are created and uploaded to GitHub, and Travis is enabled for your FooBuilder repository, then simply [creating a release](https://help.github.com/articles/creating-releases/) in your repo will trigger Travis to run, using cross-compilers to generate binaries for *all* platforms simultaneously, and finally to automatically attach the binaries to the release.

See the [troubleshooting](insert link here) and [cross-compiling](insert link here) manual sections for help with common problems.

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
build_tarballs(
    ARGS,
    "libfoo",
    sources,
    script,
    platforms,
    products,
    dependencies,
)
```

This bare-bones snippet (an adapted form of the [`libfoo` test](../../test/build_libfoo_tarballs.jl) within this repository) first identifies the sources to download and compile (there can be multiple sources listed here), then lists the `bash` commands to actually build this particular project.  Next, the `products` are defined.  These represent the output of the build process, and are how `BinaryBuilder.jl` knows that its build has succeeded.  Finally, we pass this information off to `build_tarballs()`, which takes it all in and runs the builds, placing output tarballs into the `./products` directory.

The bash commands contained within `script` will be executed for each `platform` that is passed in, so if there are platform differences that need to be addressed in the build script, using `if` statements and the `$target` environment variable can be a powerful tool.  See the [OpenBLASBuilder build script](https://github.com/staticfloat/OpenBLASBuilder/blob/master/build_tarballs.jl) for an example showcasing this.

Once the `build_tarballs()` method completes, it will have written out a `build.jl` file to download and install the generated tarballs.  This file is what will be used in Julia packages that need to use your built binaries, and is typically included within the tagged release uploads from a builder repository.  Here is an example release from the [IpoptBuilder repository](https://github.com/staticfloat/IpoptBuilder/releases/tag/v3.12.8-9), containing built tarballs as well as a `build.jl` that can be used within `Ipopt.jl`.

While constructing your own build script is certainly possible, `BinaryBuilder.jl` supports a more interactive method for building the binary dependencies and capturing the commands used to build it into a `build_tarballs.jl` file; the Wizard interface.

## Wizard interface

`BinaryBuilder.jl` contains a wizard interface that will walk you through constructing a `build_tarballs.jl` file.  To launch it, run `BinaryBuilder.run_wizard()`, and follow the instructions on-screen.

## How does this all work?

`BinaryBuilder.jl` wraps a [root filesystem](rootfs.md) that has been carefully constructed so as to provide the set of cross-compilers needed to support the wide array of platforms that Julia runs on.  This _RootFS_ is then used as the chroot jail for a sandboxed process which runs within the RootFS as if that were the whole world.  The workspace containing input source code and (eventually) output binaries is mounted within the RootFS and environment variables are setup such that the appropriate compilers for a particular target platform are used by build tools.
