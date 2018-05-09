# BinaryBuilder

[![Build Status](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl.svg?branch=master)](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl)  [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master)

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliapackaging.github.io/BinaryBuilder.jl/stable)
[![](https://img.shields.io/badge/docs-latest-blue.svg)](https://juliapackaging.github.io/BinaryBuilder.jl/latest)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Quickstart

1. Install `BinaryBuilder`
```
Pkg.add("BinaryBuilder")
```

2. Run the wizard. Be patient as it will download a rootfs image for every platform that is tested, and there are about a dozen of these.
```
using BinaryBuilder
BinaryBuilder.run_wizard()
```

3. The wizard will take you through a process of creating the `build_tarballs.jl` file. It will deploy the result to GitHub and configure Travis and GitHub releases for your package.

4. Once you complete the wizard and your repository is created on GitHub, create a new release on the `GitHub Releases` page and Travis will automatically upload binaries for all platforms to your GitHub release. It will also upload a `build.jl` file that you can use in your Julia package to import the binaries you have just built.

5. Not all platforms may be successfully built the first time. Use the iteration workflow described in the `Build Tips` section of the documentation to debug the breaking builds. Push your changes and tag a new release to test the new platforms.

6. Once you have a `build.jl` file, you can just drop it into the `deps/` folder of your Julia package and use it just like any other `build.jl` file. When it is run through `Pkg.build()`, it will generate a `deps.jl` file, which records the path of every binary that you care about. This allows package startup to be really fast; all your package has to do is `include("../deps/deps.jl")`, and it has variables that point to the location of the installed binaries.

For more information, see the documentation for this package, viewable either directly in markdown within the [`docs/src`](docs/src) folder within this repository, or [online](https://juliapackaging.github.io/BinaryBuilder.jl/latest).

# Usage

This package will help you create a distribution of binary dependencies for your julia package.
Generally this is accomplished using a dependency-specific
buildscript, or `build_tarballs.jl` file
([example](https://github.com/Keno/ReadStatBuilder/blob/master/build_tarballs.jl))
that builds the binary for all platforms. These tarballs are then suitable for
installation using
[`BinaryProvider.jl`](https://github.com/JuliaPackaging/BinaryProvider.jl).
Currently we recommend creating a separate GitHub repository for the
`build_tarballs.jl` script and using that repository's `GitHub Releases` page to
host the binaries.  (Examples for
[Nettle](https://github.com/staticfloat/NettleBuilder),
[OpenBLAS](https://github.com/staticfloat/OpenBLASBuilder) and
[Openlibm](https://github.com/staticfloat/OpenlibmBuilder))

The contents of the `build_tarballs.jl` file is relatively straightforward,
but getting it right can be a little tricky. 

# Philosophy

Building binary packages is a pain.  `BinaryBuilder` follows a philosophy that
is similar to that of building [Julia](https://julialang.org) itself; when you
want something done right, you do it yourself.

To that end, `BinaryBuilder` is designed from the ground up to facilitate the
building of packages within an easily reproducible and reliable environment,
ensuring that the built libraries and executables are deployable to every
computer that Julia itself will run on.  Packages are built using a sequence of
shell commands, packaged up inside tarballs, and hosted online for all to enjoy.
Package installation is merely downloading, verifying package integrity and
extracting that tarball on the user's computer.  No more compiling on user's
machines.  No more struggling with system package managers.  No more needing
`sudo` access to install that little mathematical optimization library.

We do not use system package managers.

We do not provide multiple ways to install a dependency.  It's download and unpack tarball, or nothing.

All packages are cross compiled. If a package does not support cross compilation, fix the package.
