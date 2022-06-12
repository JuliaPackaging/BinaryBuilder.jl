# Building Packages

A `BinaryBuilder.jl` build script (what is often referred to as a `build_tarballs.jl` file) looks something like this:

```julia
using BinaryBuilder

name = "libfoo"
version = v"1.0.1"
sources = [
    ArchiveSource("<url to source tarball>", "sha256 hash"),
]

script = raw"""
cd ${WORKSPACE}/srcdir/libfoo-*
make -j${nproc}
make install
"""

platforms = supported_platforms()

products = [
    LibraryProduct("libfoo", :libfoo),
    ExecutableProduct("fooifier", :fooifier),
]

dependencies = [
    Dependency("Zlib_jll"),
]

build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies)
```

The [`build_tarballs`](@ref) function takes in the variables defined above and
runs the builds, placing output tarballs into the `./products` directory, and
optionally generating and publishing the [JLL package](./jll.md).  Let's see in
more details what are the ingredients of the builder.

## Name

This is the name that will be used in the tarballs and for the JLL package.  It
should be the name of the upstream package, not for example that of a specific
library or executable provided by it, even though they may coincide.  The case
of the name should match that of the upstream package.  Note that the name
should be a valid Julia identifier, so it has meet some requirements, among
which:

* it cannot start with a number,
* it cannot have spaces, dashes, or dots in the name.  You can use underscores
  to replace them.

If you are unsure, you can use `Base.isidentifer` to check whehter the name is
acceptable:

```julia
julia> Base.isidentifier("valid_package_name")
true

julia> Base.isidentifier("100-invalid package.name")
false
```

Note that `_jll` will be automatically appended to the name of the generated JLL
package.

## Version number

This is the version number used in tarballs and should coincide with the version
of the upstream package.  However, note that this should only contain major,
minor and patch numbers, so

```julia
julia> v"1.2.3"
v"1.2.3"
```

is acceptable, but

```julia
julia> v"1.2.3-alpha"
v"1.2.3-alpha"

julia> v"1.2.3+3"
v"1.2.3+3"
```

or a version including more than three levels (e.g., `1.2.3.4`) are not.
Truncate the version to the patch number if necessary.

The generated JLL package will automatically add a build number, increasing it
for each rebuild of the same package version.

## Sources

The sources are what will be compiled with the build script.  They will be
placed under `${WORKSPACE}/srcdir` inside the build environment.  Sources can be
of the following types:

* [`ArchiveSource`](@ref): a compressed archive (e.g., `tar.gz`, `tar.bz2`,
  `tar.xz`, `zip`) that will be downloaded and automatically uncompressed;
* [`GitSource`](@ref): a git repository that will be automatically cloned.  The
  specified revision will be checked out;
* [`FileSource`](@ref): a generic file that will be downloaded from the
  Internet, without special treatment;
* [`DirectorySource`](@ref): a local directory whose content will be copied in
  `${WORKSPACE}/srcdir`.  This usually contains local patches used to
  non-interactively edit files in the source code of the package you want to
  build.

Example of packages with multiple sources of different types:

* [`libftd2xx`](https://github.com/JuliaPackaging/Yggdrasil/blob/62d44097a26fe338763da8263b36ce6a63e7fa9c/L/libftd2xx/build_tarballs.jl#L9-L29).

Sources are not to be confused with the [binary
dependencies](#Binary-dependencies-1).

!!! note

    Each builder should build a single package: don't use multiple sources to
    bundle multiple packages into a single recipe.  Instead, build each package
    separately, and use them as binary dependencies as appropriate.  This will
    increase reusability of packages.

## Build script

The script is a bash script executed within the build environment, which is a
`x86_64` Linux environment using the Musl C library, based on Alpine Linux
(triplet: `x86_64-linux-musl`).  The section [Build Tips](./build_tips.md)
provides more details about what you can usually do inside the build script.

## Platforms

The builder should also specify the list of platforms for which you want to
build the package.  At the time of writing, we support Linux (`x86_64`, `i686`,
`armv6l`, `armv7l`, `aarch64`, `ppc64le`), Windows (`x86_64`, `i686`), macOS
(`x86_64`, `aarch64`) and FreeBSD (`x86_64`).  When possible, we try to build
for all supported platforms, in which case you can set

```julia
platforms = supported_platforms()
```

You can get the list of the supported platforms and their associated _triplets_
by using the functions `supported_platforms` and `triplet`:

```@repl
using BinaryBuilder
supported_platforms()
triplet.(supported_platforms())
```

The triplet of the platform is used in the name of the tarball generated.

For some packages, (cross-)compilation may not be possible for all those
platforms, or you have interested in building the package only for a subset of
them.  Examples of packages built only for some platforms are

* [`libevent`](https://github.com/JuliaPackaging/Yggdrasil/blob/eb3728a2303c98519338fe0be370ef299b807e19/L/libevent/build_tarballs.jl#L24-L36);
* [`Xorg_libX11`](https://github.com/JuliaPackaging/Yggdrasil/blob/eb3728a2303c98519338fe0be370ef299b807e19/X/Xorg_libX11/build_tarballs.jl#L29):
  this is built only for Linux and FreeBSD systems, automatically filtered from
  `supported_platforms`, instead of listing the platforms explicitly.

### Expanding C++ string ABIs or libgfortran versions

Building libraries is not a trivial task and entails a lot of compatibility
issues, some of which are detailed in [Tricksy Gotchas](./tricksy_gotchas.md).

You should be aware of two incompatibilities in particular:

* The standard C++ library that comes with GCC can have one of [two incompatible
  ABIs](https://gcc.gnu.org/onlinedocs/libstdc++/manual/using_dual_abi.html) for
  `std::string`, an old one usually referred to as C++03 string ABI, and a newer
  one conforming to the 2011 C++ standard.

  !!! note

      This ABI does *not* have to do with the C++ standard used by the source
      code, in fact you can build a C++03 library with the C++11 `std::string`
      ABI and a C++11 library with the C++03 `std::string` ABI.  This is
      achieved by appropriately setting the `_GLIBCXX_USE_CXX11_ABI` macro.

  This means that when building with GCC a C++ library or program which exposes
  the `std::string` ABI, you must make sure that the user whill run a binary
  matching their `std::string` ABI.  You can manually specify the `std::string`
  ABI in the `compiler_abi` part of the platform, but `BinaryBuilder` lets you
  automatically expand the list of platform to include an entry for the C++03
  `std::string` ABI and another one for the C++11 `std::string` ABI, by using
  the [`expand_cxxstring_abis`](@ref) function:

  ```jldoctest
  julia> using BinaryBuilder

  julia> platforms = [Platform("x86_64", "linux")]
  1-element Vector{Platform}:
   Linux x86_64 {libc=glibc}

  julia> expand_cxxstring_abis(platforms)
  2-element Vector{Platform}:
   Linux x86_64 {cxxstring_abi=cxx03, libc=glibc}
   Linux x86_64 {cxxstring_abi=cxx11, libc=glibc}
  ```

  Example of packages dealing with the C++ `std::string` ABIs are:

  * [`GEOS`](https://github.com/JuliaPackaging/Yggdrasil/blob/1ba8f726810ba5315f686ef0137469a9bf6cca2c/G/GEOS/build_tarballs.jl#L33):
    expands the the C++ `std::string` ABIs for all supported platforms;
  * [`Bloaty`](https://github.com/JuliaPackaging/Yggdrasil/blob/14ee948c38385fc4dfd7b6167885fa4005b5da35/B/Bloaty/build_tarballs.jl#L37):
    builds the package only for some platforms and expands the C++ `std::string`
    ABIs;
  * [`libcgal_julia`](https://github.com/JuliaPackaging/Yggdrasil/blob/b73815bb1e3894c9ed18801fc7d62ad98fd9f8ba/L/libcgal_julia/build_tarballs.jl#L52-L57):
    builds only for platforms with C++11 `std::string` ABI.
* The `libgfortran` that comes with GCC changed the ABI in a
  backward-incompatible way in the 6.X -> 7.X and the 7.X -> 8.X transitions.
  This means that when you build a package that will link to `libgfortran`, you
  must be sure that the user will use a package linking to a `libgfortran`
  version compatible with their own.  Also in this case you can either manually
  specify the `libgfortran` version in the `compiler_abi` part fo the platform
  or use a function, [`expand_gfortran_versions`](@ref), to automatically expand
  the list of platform to include all possible `libgfortran` versions:

  ```jldoctest
  julia> using BinaryBuilder

  julia> platforms = [Platform("x86_64", "linux")]
  1-element Vector{Platform}:
   Linux x86_64 {libc=glibc}

  julia> expand_gfortran_versions(platforms)
  3-element Vector{Platform}:
   Linux x86_64 {libc=glibc, libgfortran_version=3.0.0}
   Linux x86_64 {libc=glibc, libgfortran_version=4.0.0}
   Linux x86_64 {libc=glibc, libgfortran_version=5.0.0}
  ```

  Example of packages expanding the `libgfortran` versions are:

  * [`OpenSpecFun`](https://github.com/JuliaPackaging/Yggdrasil/blob/4f20fd7c58f6ad58911345adec74deaa8aed1f65/O/OpenSpecFun/build_tarballs.jl#L34): expands the `libgfortran`
    versions for all supported platforms;
  * [`LibAMVW`](https://github.com/JuliaPackaging/Yggdrasil/blob/dbc6aa9dded5ae2fe967f262473f77f7e75f6973/L/LibAMVW/build_tarballs.jl#L65-L73):
    builds the package only for some platforms and expands the `libgfortran`
    versions.

Note that whether you need to build for different C++ string ABIs or libgfortran
versions depends exclusively on whether the products of the current build expose
the `std::string` ABI or directly link to `libgfortran`.  The fact that some of
the dependencies need to expand the C++ string ABIs or libgfortran versions is
not relevant for the current build recipe and BinaryBuilder will take care of
installing libraries with matching ABI.

Don't worry if you don't know whether you need to expand the list of platforms
for the C++ `std::string` ABIs or the libgfortran versions: this is often not
possible to know in advance without thoroughly reading the source code or
actually building the package.  In any case the audit will inform you if you
have to use these `expand-*` functions.

### Platform-independent packages

`BinaryBuilder.jl` is particularly useful to build packages involving shared
libraries and binary executables.  There is little benefit in using this package
to build a package that would be platform-independent, for example to install a
dataset to be used in a Julia package on the user's machine.  For this purpose a
simple
[`Artifacts.toml`](https://julialang.github.io/Pkg.jl/v1/artifacts/#Artifacts.toml-files-1)
file generated with
[`create_artifact`](https://julialang.github.io/Pkg.jl/v1/artifacts/#Using-Artifacts-1)
would do exactly the same job.  Nevertheless, there are cases where a
platform-independent JLL package would still be useful, for example to build a
package containing only header files that will be used as dependency of other
packages.  To build a platform-independent package you can use the special
platform [`AnyPlatform`](@ref):

```julia
platforms = [AnyPlatform()]
```

Within the build environment, an `AnyPlatform` looks like `x86_64-linux-musl`,
but this shouldn't affect your build in any way.  Note that when building a
package for `AnyPlatform` you can only have products of type `FileProduct`, as
all other types are platform-dependent.  The JLL package generated for an
`AnyPlatform` is
[platform-independent](https://julialang.github.io/Pkg.jl/v1/artifacts/#Artifact-types-and-properties-1)
and can thus be installed on any machine.

Example of builders using `AnyPlatform`:

* [`OpenCL_Headers`](https://github.com/JuliaPackaging/Yggdrasil/blob/1e069da9a4f9649b5f42547ced7273c27bd2db30/O/OpenCL_Headers/build_tarballs.jl);
* [`SPIRV_Headers`](https://github.com/JuliaPackaging/Yggdrasil/blob/1e069da9a4f9649b5f42547ced7273c27bd2db30/S/SPIRV_Headers/build_tarballs.jl).

## Products

The products are the files expected to be present in the generated tarballs.  If
a product is not found in the tarball, the build will fail.  Products can be of
the following types:

* [`LibraryProduct`](@ref): this represent a shared library;
* [`ExecutableProduct`](@ref): this represent a binary executable program.
  Note: this cannot be used for interpreted scripts;
* [`FrameworkProduct`](@ref) (only when building for `MacOS`): this represents a
  [macOS
  framework](https://en.wikipedia.org/wiki/Bundle_(macOS)#macOS_framework_bundles);
* [`FileProduct`](@ref): a file of any type, with no special treatment.

The audit will perform a series of sanity checks on the products of the builder,
with the exclusion `FileProduct`s, trying also to automatically fix some common
issues.

You don't need to list as products _all_ files that will end up in the tarball,
but only those you want to make sure are there and on which you want the audit
to perform its checks.  This usually includes the shared libraries and the
binary executables.  If you are also generating a JLL package, the products will
have some variables that make it easy to reference them.  See the documentation
of [JLL packages](./jll.md) for more information about this.

Packages listing products of different types:

* [`Fontconfig`](https://github.com/JuliaPackaging/Yggdrasil/blob/eb3728a2303c98519338fe0be370ef299b807e19/F/Fontconfig/build_tarballs.jl#L57-L69).

## Binary dependencies

A build script can depend on binaries generated by another builder. A builder
specifies `dependencies` in the form of previously-built JLL packages:

```julia
# Dependencies of Xorg_xkbcomp
dependencies = [
    Dependency("Xorg_libxkbfile_jll"),
    BuildDependency("Xorg_util_macros_jll"),
]
```

* [`Dependency`](@ref) specify a JLL package that is necessary to build and load
  the current builder.  Binaries for the target platform will be installed;
* [`RuntimeDependency`](@ref): a JLL package that is necessary only at runtime.  Its
  artifact will not be installed in the prefix during the build.
* [`BuildDependency`](@ref) is a JLL package necessary only to build the current
  package, but not to load it.  This dependency will install binaries for the
  target platforms and will not be added to the list of the dependencies of the
  generated JLL package;
* [`HostBuildDependency`](@ref): similar to `BuildDependency`, but it will
  install binaries for the host system.  This kind of dependency is usually
  added to provide some binary utilities to run during the build process.

The argument of `Dependency`, `RuntimeDependency`, `BuildDependency`, and
`HostBuildDependency` can also be a `Pkg.PackageSpec`, with which you can
specify more details about the dependency, like a version number, or also a
non-registered package.  Note that in Yggdrasil only JLL packages in the
[General registry](https://github.com/JuliaRegistries/General) can be accepted.

The dependencies for the target system (`Dependency` and `BuildDependency`) will
be installed under `${prefix}` within the build environment, while the
dependencies for the host system (`HostBuildDependency`) will be installed under
`${host_prefix}`.

In the wizard, dependencies can be specified with the prompt: *Do you require
any (binary) dependencies?  [y/N]*.

Examples of builders that depend on other binaries include:

* [`Xorg_libX11`](https://github.com/JuliaPackaging/Yggdrasil/blob/eb3728a2303c98519338fe0be370ef299b807e19/X/Xorg_libX11/build_tarballs.jl#L36-L42)
  depends on `Xorg_libxcb_jll`, and `Xorg_xtrans_jll` at build- and run-time,
  and on `Xorg_xorgproto_jll` and `Xorg_util_macros_jll` only at build-time.

### Platform-specific dependencies

By default, all dependencies are used for all platforms, but there are some
cases where a package requires some dependencies only on some platforms.  You
can specify the platforms where a dependency is needed by passing the
`platforms` keyword argument to the dependency constructor, which is the vector
of `AbstractPlatforms` where the dependency should be used.

For example, assuming that the variable `platforms` holds the vector of the
platforms for which to build your package, you can specify that `Package_jl` is
required on all platforms excluding Windows one with

```julia
Dependency("Package_jll"; platforms=filter(!Sys.iswindows, platforms))
```

The information that a dependency is only needed on some platforms is
transferred to the JLL package as well: the wrappers will load the
platform-dependent JLL dependencies only when needed.

!!! warning

    Julia's package manager doesn't have the concept of optional (or
    platform-dependent) dependencies: this means that when installing a JLL
    package in your environment, all of its dependencies will always be
    installed as well in any case.  It's only at runtime that platform-specific
    dependencies will be loaded where necessary.

    For the same reason, even if you specify a dependency to be not needed on
    for a platform, the build recipe may still pull it in if that's also an
    indirect dependency required by some other dependencies.  At the moment
    `BinaryBuilder.jl` isn't able to propagate the information that a dependency
    is platform-dependent when installing the artifacts of the dependencies.

Examples:

* [`ADIOS2`](https://github.com/JuliaPackaging/Yggdrasil/blob/0528e0f31b55355df632c79a2784621583443d9c/A/ADIOS2/build_tarballs.jl#L122-L123)
  uses `MPICH_jll` to provide an MPI implementations on all platforms excluding
  Windows, and `MicrosoftMPI_jll` for Windows.
* [`GTK3`](https://github.com/JuliaPackaging/Yggdrasil/blob/0528e0f31b55355df632c79a2784621583443d9c/G/GTK3/build_tarballs.jl#L70-L104)
  uses the X11 software stack only on Linux and FreeBSD platforms, and Wayland
  only on Linux.
* [`NativeFileDialog`](https://github.com/JuliaPackaging/Yggdrasil/blob/0528e0f31b55355df632c79a2784621583443d9c/N/NativeFileDialog/build_tarballs.jl#L40-L44)
  uses GTK3 only on Linux and FreeBSD, on all other platforms it uses system
  libraries, so no other packages are needed in those cases.

### Version number of dependencies

There are two different ways to specify the version of a dependency, with two
different meanings:

* `Dependency("Foo_jll", v"1.2.3")`: the second argument of `Dependency`
  specifies the version of the package to be used for building: this version *is
  not* reflected into a compatibility bound in the project of the generated JLL
  package.  This is useful when the package you want to build is compatible with
  all the versions of the dependency starting from the given one (and then you
  don't want to restrict compatibility bounds of the JLL package), but to
  maximize compatibility you want to build against the oldest compatible
  version.
* `Dependency(PackageSpec(; name="Foo_jll", version=v"1.2.3"))`: if the package
  is given as a `Pkg.PackageSpec` and the `version` keyword argument is given,
  this version of the package is used for the build *and* the generated JLL
  package will be compatible with the provided version of the package.  This
  should be used when your package is compatible only with a single version of
  the dependency, a condition that you want to reflect also in the project of the
  JLL package.

# Building and testing JLL packages locally

As a package developer, you may want to test JLL packages locally, or as a binary dependency
developer you may want to easily use custom binaries.  Through a combination of `dev`'ing out
the JLL package and creating an `overrides` directory, it is easy to get complete control over
the local JLL package state.

## Overriding a prebuilt JLL package's binaries

After running `pkg> dev LibFoo_jll`, a local JLL package will be checked out to your depot's
`dev` directory (on most installations this is `~/.julia/dev`) and by default the JLL package
will make use of binaries within your depot's `artifacts` directory.  If an `override`
directory is present within the JLL package directory, the JLL package will look within that
`override` directory for binaries, rather than in any artifact directory.  Note that there is
no mixing and matching of binaries within a single JLL package; if an `override` directory is
present, all products defined within that JLL package must be found within the `override`
directory, none will be sourced from an artifact.  Dependencies (e.g. found within another
JLL package) may still be loaded from their respective artifacts, so dependency JLLs must
themselves be `dev`'ed and have `override` directories created with files or symlinks
created within them.

### Auto-populating the `override` directory

To ease creation of an `override` directory, JLL packages contain a `dev_jll()` function,
that will ensure that a `~/.julia/dev/<jll name>` package is `dev`'ed out, and will copy the
normal artifact contents into the appropriate `override` directory.  This will result in no
functional difference from simply using the artifact directory, but provides a template of
files that can be replaced by custom-built binaries.

Note that this feature is rolling out to new JLL packages as they are rebuilt; if a JLL
package does not have a `dev_jll()` function, [open an issue on Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil/issues/new)
and a new JLL version will be generated to provide the function.

## Building a custom JLL package locally

When building a new version of a JLL package, if `--deploy` is passed to
`build_tarballs.jl` then a newly-built JLL package will be deployed to a GitHub
repository.  (Read the documentation in the [Command Line](@ref) section or
given by passing `--help` to a `build_tarballs.jl` script for more on `--deploy`
options).  If `--deploy=local` is passed, the JLL package will still be built in
the `~/.julia/dev/` directory, but it will not be uploaded anywhere.  This is
useful for local testing and validation that the built artifacts are working
with your package.
