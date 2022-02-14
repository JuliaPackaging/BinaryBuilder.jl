# JLL packages

`BinaryBuilder.jl` is designed to produce tarballs that can be used in any
environment, but so far their main use has been to provide pre-built libraries
and executables to be readily used in Julia packages.  This is accomplished by
JLL packages (a pun on "Dynamic-Link Library", with the J standing for Julia).
They can be installed like any other Julia packages with the [Julia package
manager](https://julialang.github.io/Pkg.jl/v1/) in the REPL with
```
]add NAME_jll
```
and then loaded with
```
using NAME_jll
```
However, most users will not ever need to do these steps on their own, JLL
packages are usually only used as dependencies of packages wrapping binary
libraries or executables.

Most JLL packages live under the
[`JuliaBinaryWrappers`](https://github.com/JuliaBinaryWrappers) organization on
GitHub, and the builders to generate them are maintaned in
[Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil/), the community build
tree.  `BinaryBuilder.jl` allows anyone to create their own JLL package and
publish them to a GitHub repository of their choice without using Yggdrasil, see
the [Frequently Asked Questions](@ref).

## Anatomy of a JLL package

A somewhat popular misconception is that JLL packages are "special".  Instead,
they are simple Julia packages with a common structure, as they are generated
automatically.  This is the typical tree of a JLL package, called in this
example `NAME_jll.jl`:
```
NAME_jll
├── Artifacts.toml
├── LICENSE
├── Project.toml
├── README.md
└── src/
    ├── NAME_jll.jl
    └── wrappers/
        ├── aarch64-linux-gnu.jl
        ├── aarch64-linux-musl.jl
        ├── armv7l-linux-gnueabihf.jl
        ├── armv7l-linux-musleabihf.jl
        ├── i686-linux-gnu.jl
        ├── i686-linux-musl.jl
        ├── i686-w64-mingw32.jl
        ├── powerpc64le-linux-gnu.jl
        ├── x86_64-apple-darwin14.jl
        ├── x86_64-linux-gnu.jl
        ├── x86_64-linux-musl.jl
        ├── x86_64-unknown-freebsd11.1.jl
        └── x86_64-w64-mingw32.jl
```

These are the main ingredients of a JLL package:

* `LICENSE`, a file stating the license of the JLL package.  Note that this may
  differ from the license of the library it wraps, which is instead shipped
  inside the tarballs;
* a [`README.md`](https://en.wikipedia.org/wiki/README) file providing some
  information about the content of the wrapper, like the list of "products"
  provided by the package;
* the [`Artifacts.toml`
  file](https://julialang.github.io/Pkg.jl/v1/artifacts/#Artifacts.toml-files-1)
  contains the information about all the available tarballs for the given
  package.  The tarballs are uploaded to GitHub releases;
* the
  [`Project.toml`](https://julialang.github.io/Pkg.jl/v1/toml-files/#Project.toml-1)
  file describes the packages dependencies and their compatibilities;
* the main entry point of the package is the file called `src/NAME_jll.jl`.
  This is what is executed when you issue the command
  ```jl
  using NAME_jll
  ```
  This file reads the list of tarballs available in `Artifacts.toml` and choose
  the platform matching the current platform.  Some JLL packages are not built
  for all supported platforms.  If the current platform is one of those platform
  not supported by the JLL package, this is the end of the package.  Instead, if
  the current platform is supported, the corresponding wrapper in the
  `src/wrappers/` directory will be included;
* the `wrappers/` directory contains a file for each of the supported
  platforms.  They are actually mostly identical, with some small differences
  due to platform-specific details.  The wrappers are analyzed in more details
  in the following section.

## The wrappers

The files in the `src/wrappers/` directory are very thin automatically-generated
wrappers around the binary package provided by the JLL package.  They load all
the JLL packages that are dependencies of the current JLL package and export the
names of the products listed in the `build_tarballs.jl` script that produced the
current JLL package.  Among others, they also define the following unexported
variables:

* `artifact_dir`: the absolute path to where the artifact for the current
  platform has been installed.  This is the "prefix" where the
  binaries/libraries/files are placed;
* `PATH`: the value of the
  [`PATH`](https://en.wikipedia.org/wiki/PATH_(variable)) environment variable
  needed to run executables in the current JLL package, if any;
* `PATH_list`: the list of directories in `PATH` as a vector of `String`s;
* `LIBPATH`: the value of the environment variable that holds the list of
  directories in which to search shared libraries.  This has the correct value
  for the libraries provided by the current JLL package;
* `LIBPATH_list`: the list of directories in `LIBPATH` as a vector of `String`s.

The wrapper files for each platform also define the
[`__init__()`](https://docs.julialang.org/en/v1/manual/modules/index.html#Module-initialization-and-precompilation-1)
function of the JLL package, the code that is executed every time the package is
loaded.  The `__init__()` function will populate most of the variables mentioned
above and automatically open the shared libraries, if any, listed in the
products of the `build_tarballs.jl` script that generated the JLL package.

The rest of the code in the wrappers is specific to each of the products of the
JLL package and detailed below.  If you want to see a concrete example of a
package providing all the main three products, have a look at
[`Fontconfig_jll.jl`](https://github.com/JuliaBinaryWrappers/Fontconfig_jll.jl/tree/785936d816d1ae65c2a6648f3a6acbfd72535e36).

In addition to the variables defined above by each JLL wrapper, the package
[`JLLWrappers`](https://github.com/JuliaPackaging/JLLWrappers.jl) defines an
additional unexported variable:

* `LIBPATH_env`: the name of the environment variable of the search paths of the
  shared libraries for the current platform.  This is equal to `LD_LIBRARY_PATH`
  on Linux and FreeBSD, `DYLD_FALLBACK_LIBRARY_PATH` on macOS, and `PATH` on
  Windows.

In what follows, we will use as an example a builder that has these products:

```julia
products = [
    FileProduct("src/data.txt", :data_txt),
    LibraryProduct("libdataproc", :libdataproc),
    ExecutableProduct("mungify", :mungify_exe),
]
```

### LibraryProduct

A [`LibraryProduct`](@ref) is a shared library that can be
[`ccall`](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/)ed
from Julia.  Assuming that the product is called `libdataproc`, the wrapper
defines the following variables:

* `libdataproc`: this is the exported
  [`const`](https://docs.julialang.org/en/v1/manual/variables-and-scoping/#Constants-1)
  variable that should be used in
  [`ccall`](https://docs.julialang.org/en/v1/manual/calling-c-and-fortran-code/index.html):

  ```julia
  num_chars = ccall((:count_characters, libdataproc), Cint,
                    (Cstring, Cint), data_lines[1], length(data_lines[1]))
  ```

  Roughly speaking, the value of this variable is the basename of the shared
  library, not its full absolute path;
* `libdataproc_path`: the full absolute path of the shared library.  Note that
  this is not `const`, thus it can't be used in `ccall`;
* `libdataproc_handle`: the address in memory of the shared library after it has
  been loaded at initialization time.

### ExecutableProduct

An [`ExecutableProduct`](@ref) is a binary executable that can be run on the
current platform.  If, for example, the `ExecutableProduct` has been called
`mungify_exe`, the wrapper defines an exported function named `mungify_exe` that
should run by the user in one the following ways:

```julia
# Only available in Julia v1.6+
run(`$(mungify_exe()) $arguments`)
```

```julia
mungify_exe() do exe
    run(`$exe $arguments`)
end
```

Note that in the latter form `exe` can be replaced with any name of your choice:
with the
[`do`-block](https://docs.julialang.org/en/v1/manual/functions/#Do-Block-Syntax-for-Function-Arguments-1)
syntax you are defining the name of the variable that will be used to actually
call the binary with
[`run`](https://docs.julialang.org/en/v1/base/base/#Base.run).

The former form is only available when using Julia v1.6, but should be
preferred going forward, as it is thread-safe and generally more flexible.

A common point of confusion about `ExecutableProduct`s in JLL packages is why
these function wrappers are needed: while in principle you could run the
executable directly by using its absolute path in `run`, these functions ensure
that the executable will find all shared libraries it needs while running.

In addition to the function called `mungify_exe`, for this product there will be
the following unexported variables:

* `mungify_exe_path`: the full absolute path of the executable;

### FileProduct

A [`FileProduct`](@ref) is a simple file with no special treatment.  If, for
example, the `FileProduct` has been called `data_txt`, the only variables
defined for it are:

* `data_txt`: this exported variable has the absolute path to the mentioned
  file:

  ```julia
  data_lines = open(data_txt, "r") do io
      readlines(io)
  end
  ```

* `data_txt_path`: this unexported variable is actually equal to `data_txt`, but
  is kept for consistency with all other product types.

## Overriding the artifacts in JLL packages

As explained above, JLL packages use the [Artifacts
system](https://julialang.github.io/Pkg.jl/v1/artifacts) to provide the files.
If you wish to override the content of an artifact with their own
binaries/libraries/files, you can use the [`Overrides.toml`
file](https://julialang.github.io/Pkg.jl/v1/artifacts/#Overriding-artifact-locations-1).

We detail below a couple of different ways to override the artifact of a JLL
package, depending on whether the package is `dev`'ed or not.  The second method
is particularly recommended to system administrator who wants to use system
libraries in place of the libraries in JLL packages.

### `dev`'ed JLL packages

In the event that a user wishes to override the content within a `dev`'ed JLL
package, the user may use the `dev_jll()` method provided by JLL packages to
check out a mutable copy of the package to their `~/.julia/dev` directory.  An
`override` directory will be created within that package directory, providing a
convenient location for the user to copy in their own files over the typically
artifact-sourced ones.  See the segment on "Building and testing JLL packages
locally" in the [Building Packages](./building.md) section of this documentation
for more information on this capability.

### Non-`dev`'ed JLL packages

As an example, in a Linux system you can override the Fontconfig library provided by
[`Fontconfig_jll.jl`](https://github.com/JuliaBinaryWrappers/Fontconfig_jll.jl) and the
Bzip2 library provided by
[`Bzip2_jll.jl`](https://github.com/JuliaBinaryWrappers/Bzip2_jll.jl)
respectively with `/usr/lib/libfontconfig.so` and `/usr/local/lib/libbz2.so` with the
following `Overrides.toml`:
```toml
[a3f928ae-7b40-5064-980b-68af3947d34b]
Fontconfig = "/usr"

[6e34b625-4abd-537c-b88f-471c36dfa7a0]
Bzip2 = "/usr/local"
```
Some comments about how to write this file:
* The UUIDs are those of the JLL packages,
  `a3f928ae-7b40-5064-980b-68af3947d34b` for `Fontconfig_jll.jl` and
  `6e34b625-4abd-537c-b88f-471c36dfa7a0` for `Bzip2_jll.jl`.  You can either
  find them in the `Project.toml` files of the packages (e.g., see [the
  `Project.toml` file of
  `Fontconfig_jll`](https://github.com/JuliaBinaryWrappers/Fontconfig_jll.jl/blob/8904cd195ea4131b89cafd7042fd55e6d5dea241/Project.toml#L2))
  or look it up in the registry (e.g., see [the entry for `Fontconfig_jll` in
  the General
  registry](https://github.com/JuliaRegistries/General/blob/caddd31e7878276f6e052f998eac9f41cdf16b89/F/Fontconfig_jll/Package.toml#L2)).
* The artifacts provided by JLL packages have the same name as the packages,
  without the trailing `_jll`, `Fontconfig` and `Bzip2` in this case.
* The artifact location is held in the `artifact_dir` variable mentioned above,
  which is the "prefix" of the installation of the package.  Recall the paths of
  the products in the JLL package is relative to `artifact_dir` and the files
  you want to use to override the products of the JLL package must have the same
  tree structure as the artifact.  In our example we need to use `/usr` to
  override Fontconfig and `/usr/local` for Bzip2.

### Overriding specific products

Instead of overriding the entire artifact, you can override a particular product
(library, executable, or file) within a JLL using
[Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl).

!!! compat
    This section requires Julia 1.6 or later.

For example, to override our `libbz2` example:
```julia
using Preferences
set_preferences!(
    "LocalPreferences.toml",
    "Bzip2_jll",
    "libbzip2_path" => "/usr/local/lib/libbz2.so",
)
```
Note that the product name is `libbzip2`, but we use `libbzip2_path`.

!!! warning
    There are two common cases where this will not work:
    1. The JLL is part of the [Julia stdlib](https://github.com/JuliaLang/julia/tree/master/stdlib),
       for example `Zlib_jll`
    2. The JLL has not been compiled with [JLLWrappers.jl](https://github.com/JuliaPackaging/JLLWrappers.jl)
       as a dependency. In this case, it means that the last build of the JLL
       pre-dates the introduction of the JLLWrappers package and needs a fresh
       build. Please open an issue on [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil/)
       requesting a new build, or make a pull request to update the relevant
       `build_tarballs.jl` script.

