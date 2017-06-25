# BinDeps2

[![Build Status](https://travis-ci.org/staticfloat/BinDeps2.jl.svg?branch=master)](https://travis-ci.org/staticfloat/BinDeps2.jl)  [![Coverage Status](https://coveralls.io/repos/staticfloat/BinDeps2.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/staticfloat/BinDeps2.jl?branch=master)  [![codecov.io](http://codecov.io/github/staticfloat/BinDeps2.jl/coverage.svg?branch=master)](http://codecov.io/github/staticfloat/BinDeps2.jl?branch=master)

"Yea, though I walk through the valley of the shadow of death, I will fear no evil"

# Philosophy

Building binary packages is a pain.  `BinDeps2` is here to make your life easier.  `BinDeps2` follows a philosophy that is similar to that of building [Julia](https://julialang.org) itself; when you want something done right, you do it yourself.

To that end, `BinDeps2` is designed from the ground up to facillitate the building of packages within an easily reproducible and reliable environment, ensuring that the built libraries and executables are deployable to every computer that Julia itself will run on.  Packages are built using a sequence of shell commands, packaged up inside tarballs, and hosted online for all to enjoy.  Package installation is merely downloading, verifying and extracting that tarball on the user's computer.  No more compiling on user's machines.  No more struggling with system package managers.  No more needing `sudo` access to install that little mathematical optimization library.

We do not use system package managers.

We do not provide multiple ways to install a dependency.

# Implementation

WIP

# Usage example

WIP