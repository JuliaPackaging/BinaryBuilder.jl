# BETA SOFTWARE

Though most of the design work has been completed, the code monkeys are still hard at work tinkering to develop the best possible binary building solution for [Julia](https://julialang.org). Feel free to use this software, but please note
that there may be bugs and issues still being worked out. This software is provided AS-IS with no warranty, implied or otherwise, and is not even guaranteed to be fit for a particular purpose.

The primary target platform of this package is Linux.
Windows is currently not supported. Please note that although preliminary OS X
support exists, it is experimental and recommended only to those wanting to help
out with porting this package to new platforms.

# BinaryBuilder

[![Build Status](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl.svg?branch=master)](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl)  [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Usage

This package will help you create a distribution of binary dependencies for your
julia package. Generally this is accomplished using a dependency-specific,
`build_tarballs.jl` file ([example](https://github.com/Keno/ReadStatBuilder/blob/master/build_tarballs.jl))
that builds the binary for all platforms. These tarballs are then suitable for
installation using `BinaryProvider.jl`. Currently we recommend creating a
separate GitHub repository for the `build_tarballs.jl` script and using that
repository's `GitHub Releases` page to host the binaries.

The contents of the `build_tarballs.jl` file is relatively straightforward,
but getting it right can be a little tricky. To ease the burden of creating
said file, you may use the BinaryBuilder wizard:

```
using BinaryBuilder
BinaryBuilder.run_wizard()
```

The wizard will take you through creating the `build_tarballs.jl` file and help
you deploy the result to GitHub with Travis and GitHub releases set up properly.
Once you complete the wizard and your repository is created on GitHub, create
a new release on the `GitHub Releases` page and Travis will automatically add
binaries for all platforms, as well as a build.jl file that you can use in your
julia package to import the binaries you have just built.

# Philosophy

Building binary packages is a pain.  `BinaryBuilder` is here to make your life easier.  `BinaryBuilder` follows a philosophy that is similar to that of building [Julia](https://julialang.org) itself; when you want something done right, you do it yourself.

To that end, `BinaryBuilder` is designed from the ground up to facilitate the building of packages within an easily reproducible and reliable environment, ensuring that the built libraries and executables are deployable to every computer that Julia itself will run on.  Packages are built using a sequence of shell commands, packaged up inside tarballs, and hosted online for all to enjoy.  Package installation is merely downloading, verifying and extracting that tarball on the user's computer.  No more compiling on user's machines.  No more struggling with system package managers.  No more needing `sudo` access to install that little mathematical optimization library.

We do not use system package managers.

We do not provide multiple ways to install a dependency.  It's download and unpack tarball, or nothing.

All packages are cross compiled. If a package does not support cross compilation, fix the package.

# Implementation

`BinaryBuilder.jl` utilizes a cross-compilation environment exposed as a Linux container. 
On Linux this makes use of a light-weight custom container engine, on OS X (and
Windows in the future), we use qemu and hardware accelerated virtualization to
provide the environment. The environment contains cross-compilation toolchains stored in `/opt/<target triplet>`. See [`target_envs()`](https://github.com/JuliaPackaging/BinaryBuilder.jl/blob/76a3073753bd017aaf522ed068ea29418f1059c0/src/DockerRunner.jl#L108-L133) for an example of what kinds of environment variables are defined in order to run the proper tools for a particular cross-compilation task.

# Known issues

* Binary projects that require `clang` or some other non-GCC compiler will not work, as the cross-compilation environment only supports GCC at the moment.

* Projects that require some form of bootstrapping (e.g. compiling an executable, then running that executable and using the output for further build steps) will not work, as the cross-compilation environment does not support running anything other than `x86_64` Linux executables.  It is entirely possible that this is solvable using compatibility layers such as [Wine](https://www.winehq.org/) for Windows and [Darling](http://darlinghq.org/) for macOS, or even [qemu](https://www.qemu.org/) for non-Intel targets, but this is a big TODO item.
