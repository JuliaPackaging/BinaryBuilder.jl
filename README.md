# BinaryBuilder

[![Build Status](https://dev.azure.com/JuliaPackaging/BinaryBuilder.jl/_apis/build/status/JuliaPackaging.BinaryBuilder.jl?branchName=master)](https://dev.azure.com/JuliaPackaging/BinaryBuilder.jl/_build/latest?definitionId=2&branchName=master) [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master) 

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://docs.binarybuilder.org/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://docs.binarybuilder.org/dev)

> "Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Quickstart

1. Install `BinaryBuilder`
```julia
using Pkg; Pkg.add("BinaryBuilder")
```

2. Run the wizard. 
```julia
using BinaryBuilder
BinaryBuilder.run_wizard()
```

3. The wizard will take you through a process of building your software package. Note that the wizard may need to download a new compiler shard for each platform targeted, and there are quite a few of these, so a fast internet connection can be helpful.  The output of this stage is a `build_tarballs.jl` file, which is most commonly deployed as a pull request to the community buildtree [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil).  For experienced users, it is often more convenient to directly copy/modify an existing `build_tarballs.jl` file within Yggdrasil, then simply open a pull request where CI will test building the binary artifacts for all platforms again.

4. The output of a build is a JLL package (typically hosted within the [JuliaBinaryWrappers](https://github.com/JuliaBinaryWrappers/) GitHub organization) which can be added to packages just like any other Julia package.  The JLL package will export bindings for all products defined within the build recipe.

For more information, see the documentation for this package, viewable either directly in markdown within the [`docs/src`](docs/src) folder within this repository, or [online](https://docs.binarybuilder.org).

# Philosophy

Building binary packages is a pain.  `BinaryBuilder` follows a philosophy that is similar to that of building [Julia](https://julialang.org) itself; when you want something done right, you do it yourself.  To that end, `BinaryBuilder` is designed from the ground up to facilitate the building of packages within an easily reproducible and reliable Linux environment, ensuring that the built libraries and executables are deployable to every platform that Julia itself will run on.  Packages are cross-compiled using a sequence of shell commands, packaged up inside tarballs, and hosted online for all to enjoy.  Package installation is merely downloading, verifying package integrity and extracting that tarball on the user's computer.  No more compiling on user's machines.  No more struggling with system package managers.  No more needing `sudo` access to install that little mathematical optimization library.

All packages are cross compiled. If a package does not support cross compilation, we patch the package or, in extreme cases, rebundle prebuilt executables.

The cross-compilation environment that we use is a homegrown Linux environment with many different compilers built for it, including various versions of `gcc`, `clang`, `gfortran`, `rustc` and `go`.  You can read more about this in [the `RootFS.md` file](https://github.com/JuliaPackaging/Yggdrasil/blob/master/RootFS.md) within the Yggdrasil repository.
