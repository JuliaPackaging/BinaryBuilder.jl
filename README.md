# PRE-ALPHA SOFTWARE

The code monkeys are still hard at work tinkering to develop the best possible binary building solution for [Julia](https://julialang.org). Please **do not use this software** for any real work until this notice is removed.  This software is provided AS-IS with no warranty, implied or otherwise, and is not even guaranteed to be fit for a particular purpose.

# BinaryBuilder

[![Build Status](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl.svg?branch=master)](https://travis-ci.org/JuliaPackaging/BinaryBuilder.jl)  [![Build status](https://ci.appveyor.com/api/projects/status/feqn75vl4k5ia6nj?svg=true)](https://ci.appveyor.com/project/JuliaPackaging/binarybuilder-jl)  [![codecov.io](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaPackaging/BinaryBuilder.jl?branch=master)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Philosophy

Building binary packages is a pain.  `BinaryBuilder` is here to make your life easier.  `BinaryBuilder` follows a philosophy that is similar to that of building [Julia](https://julialang.org) itself; when you want something done right, you do it yourself.

To that end, `BinaryBuilder` is designed from the ground up to facillitate the building of packages within an easily reproducible and reliable environment, ensuring that the built libraries and executables are deployable to every computer that Julia itself will run on.  Packages are built using a sequence of shell commands, packaged up inside tarballs, and hosted online for all to enjoy.  Package installation is merely downloading, verifying and extracting that tarball on the user's computer.  No more compiling on user's machines.  No more struggling with system package managers.  No more needing `sudo` access to install that little mathematical optimization library.

We do not use system package managers.

We do not provide multiple ways to install a dependency.

# Implementation

WIP

# Usage example

WIP
