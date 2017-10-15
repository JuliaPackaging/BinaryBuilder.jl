# PRE-ALPHA SOFTWARE

The code monkeys are still hard at work tinkering to develop the best possible binary building solution for [Julia](https://julialang.org). Please **do not use this software** for any real work until this notice is removed.  This software is provided AS-IS with no warranty, implied or otherwise, and is not even guaranteed to be fit for a particular purpose.

# BinaryBuilder

[![Build Status](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl.svg?branch=master)](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl)  [![Build status](https://ci.appveyor.com/api/projects/status/feqn75vl4k5ia6nj?svg=true)](https://ci.appveyor.com/project/JuliaPackaging/binarybuilder-jl)  [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Philosophy

Building binary packages is a pain.  `BinaryBuilder` is here to make your life easier.  `BinaryBuilder` follows a philosophy that is similar to that of building [Julia](https://julialang.org) itself; when you want something done right, you do it yourself.

To that end, `BinaryBuilder` is designed from the ground up to facillitate the building of packages within an easily reproducible and reliable environment, ensuring that the built libraries and executables are deployable to every computer that Julia itself will run on.  Packages are built using a sequence of shell commands, packaged up inside tarballs, and hosted online for all to enjoy.  Package installation is merely downloading, verifying and extracting that tarball on the user's computer.  No more compiling on user's machines.  No more struggling with system package managers.  No more needing `sudo` access to install that little mathematical optimization library.

We do not use system package managers.

We do not provide multiple ways to install a dependency.  It's download and unpack tarball, or nothing.

# Implementation

`BinaryBuilder.jl` utilizes a cross-compilation environment built into a [Docker](https://www.docker.com) image to compile binary objects for multiple operating systems and architectures.  The Dockerfiles for creating this cross-compilation environment are hosted in [the `staticfloat/julia-docker` repository](https://github.com/staticfloat/julia-docker/blob/master/crossbuild/crossbuild-x64.harbor).  The docker image contains cross-compilation toolchains stored in `/opt/<target triplet>`, see [`target_envs()`](https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/76a3073753bd017aaf522ed068ea29418f1059c0/src/DockerRunner.jl#L108-L133) for an example of what kinds of environment variables are defined in order to run the proper tools for a particular cross-compilation task.

A build is represented by a [`Dependency` object](https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/76a3073753bd017aaf522ed068ea29418f1059c0/src/Dependency.jl#L17-L36), which is used to bundle together all the build steps required to actually build an object, perform the build, write out logs for each step, and finally package it all up as a nice big tarball.  At the end of a `build()`, a series of audit steps are run, checking for common problems such as missing libraries.  These checks typically do not stop a build, but you should pay attention to them, as they do their best to be helpful.  Occasionally, an error can be automatically fixed.  If you set the `autofix` parameter to `build()` to be `true`, this will be attempted.

# Usage example

Usage is as simple as defining a `Dependency`, `build()`'ing it, then packaging it up.  Example:

```julia
prefix = Prefix("/source_code")
cd("/source_code") do
    libfoo = LibraryProduct(prefix, "libfoo")
    steps = [`make clean`, `make install`]
    dep = Dependency("foo", [libfoo], steps, :linux64, prefix)
    build(dep)
end
tarball_path = package(prefix, "/build_out/libfoo", platform=platform)
```

For a full example, see [`build_libfoo_tarballs.jl` in the test directory](test/build_libfoo_tarballs.jl).  For a more in-depth example, see [the NettleBuilder repository](https://github.com/staticfloat/NettleBuilder).

# Known issues

* Binary projects that require `clang` or some other non-GCC compiler will not work, as the cross-compilation environment only supports GCC at the moment.

* Projects that require some form of bootstrapping (e.g. compiling an executable, then running that executable and using the output for further build steps) will not work, as the cross-compilation environment does not support running anything other than `x86_64` Linux executables.  It is entirely possible that this is solvable using compatibility layers such as [Wine](https://www.winehq.org/) for Windows and [Darling](http://darlinghq.org/) for MacOS, or even [qemu](https://www.qemu.org/) for non-Intel targets, but this is a big TODO item.