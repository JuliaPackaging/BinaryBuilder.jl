# BinaryBuilder

[![Build Status](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl.svg?branch=master)](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl)  [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master)

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliapackaging.github.io/BinaryBuilder.jl/stable)
[![](https://img.shields.io/badge/docs-latest-blue.svg)](https://juliapackaging.github.io/BinaryBuilder.jl/latest)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Usage

This package will help you create a distribution of binary dependencies for your
julia package. Generally this is accomplished using a dependency-specific
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

For more information, see the documentation for this package, viewable either directly in markdown within the [`docs/src`](docs/src) folder within this repository, or [online](https://juliapackaging.github.io/BinaryBuilder.jl/latest).

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