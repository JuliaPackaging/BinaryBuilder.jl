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
  platform has been installed;
* `PATH`: the value of the
  [`PATH`](https://en.wikipedia.org/wiki/PATH_(variable)) environment variable
  needed to run executables in the current JLL package, if any;
* `PATH_list`: the list of directories in `PATH` as a vector of `String`s;
* `LIBPATH`: the value of the environment variable that holds the list of
  directories in which to search shared libraries.  This has the correct value
  for the libraries provided by the current JLL package;
* `LIBPATH_list`: the list of directories in `LIBPATH` as a vector of `String`s;
* `LIBPATH_env`: the name of the environment variable of the search paths of the
  shared libraries for the current platform.  This is equal to `LD_LIBRARY_PATH`
  on Linux and FreeBSD, `DYLD_FALLBACK_LIBRARY_PATH` on macOS, and `PATH` on
  Windows;

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
* `libdataproc_splitpath`: the path of the shared library, relative to
  `artifact_dir`, as returned by
  [`splitpath`](https://docs.julialang.org/en/v1/base/file/#Base.Filesystem.splitpath);
* `libdataproc_path`: the full absolute path of the shared library.  Note that
  this is not `const`, thus it can't be used in `ccall`;
* `libdataproc_handle`: the address in memory of the shared library after it has
  been loaded at initialization time.

### ExecutableProduct

An [`ExecutableProduct`](@ref) is a binary executable that can be run on the
current platform.  If, for example, the `ExecutableProduct` has been called
`mungify_exe`, the wrapper defines an exported function named `mungify_exe` that
should run by the user in the following way:

```julia
mungify_exe() do exe
    run(`$exe $arguments`)
end
```

Note that in this example `exe` can be replaced with any name of your choice:
with the
[`do`-block](https://docs.julialang.org/en/v1/manual/functions/#Do-Block-Syntax-for-Function-Arguments-1)
syntax you are defining the name of the variable that will be used to actually
call the binary with
[`run`](https://docs.julialang.org/en/v1/base/base/#Base.run).

A common point of confusion about `ExecutableProduct`s in JLL packages is why
this function is needed: while in principle you could directly run the
executable directly by using its absolute path in `run`, this wrapper function
ensures that the executable will find all shared libraries it needs while running.

In addition to the function called `mungify_exe`, for this product there will be
the following unexported variables:

* `mungify_exe_splitpath`: the path of the executable, relative to
  `artifact_dir`, as returned by
  [`splitpath`](https://docs.julialang.org/en/v1/base/file/#Base.Filesystem.splitpath);
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
