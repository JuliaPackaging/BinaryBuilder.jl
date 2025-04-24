# Tips for Building Packages

BinaryBuilder provides a convenient environment to enable cross-platform building. But, many libraries have complicated build scripts that may need to be adapted to support all of the BinaryBuilder targets.

If your build fails with some errors, look at the [Build Troubleshooting](@ref) page.

*If you have additional tips, please submit a PR with suggestions.*

## Build strategy

What BinaryBuilder does is to create a tarball containing all files that are found inside the `${prefix}` directory at the end of the build and which don't come from the dependencies listed in the build recipe.
Thus, what you want to do in a build script is to install the relevant files under the appropriate directories in `${prefix}` (see the [Automatic environment variables](@ref) section): the libraries in `${libdir}`, the binary executables in `${bindir}`, etc...
Most packages come with a build system to automate this process (GNU Autoconf, CMake, Meson, a plain Makefile, etc...), but sometimes you may need to manually move the files as appropriate.

## Initiating different shell commands based on target

Sometimes, you need to adapt build scripts based on the target platform. This can be done within the shell script. Here is an example from [`OpenBLAS`](https://github.com/JuliaPackaging/Yggdrasil/blob/685cdcec9f0f0a16f7b90a1671af88326dcf5ab1/O/OpenBLAS/build_tarballs.jl):

```sh
# Set BINARY=32 on i686 platforms and armv7l
if [[ ${nbits} == 32 ]]; then
    flags="${flags} BINARY=32"
fi
```

Here are other examples of scripts with target-specific checks:

* [Kaleido](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/K/Kaleido/build_tarballs.jl#L20-L25) - Different steps for Windows and macOS
* [Libical](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/L/Libical/build_tarballs.jl#L21-L25) - 32-bit check

It is also possible to run quite different scripts for each target by running different build scripts for different sets of targets. Here is an example where windows builds are separated from other targets:

* [Git](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/G/Git/build_tarballs.jl#L22-L26)

## Autoconfigure builds

Autoconfigure builds are generally quite straightforward. Here is a typical approach:

```sh
./configure --prefix=$prefix --build=${MACHTYPE} --host=${target}
make -j${nproc}
make install
```

Here are examples of autoconfigure build scripts:

* [Patchelf](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/P/Patchelf/build_tarballs.jl#L18-L20)
* [LibCURL](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/L/LibCURL/build_tarballs.jl#L55-L57)


## CMake builds

For CMake, the wizard will suggest a template for running CMake. Typically, this will look like:

```sh
cmake -B build -DCMAKE_INSTALL_PREFIX=${prefix} -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel ${nproc}
cmake --install build
```

CMake makes it hard to cleanup a partial failed build and start over, so we always recommend configuring and building a CMake project in a dedicated new directory, `build` in the example above.

The toolchain file sets up several CMake environment variables for better cross-platform support, such as `CMAKE_SYSROOT`, `CMAKE_C_COMPILER`, etc...  Examples of builds that include CMake parts include:

* [JpegTurbo](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/J/JpegTurbo/build_tarballs.jl#L19-L21)

* [Sundials](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/S/Sundials/Sundials%405/build_tarballs.jl#L42-L55)
  - Needs to copy *.dll files from `${prefix}/lib` to `${libdir}` for Windows
  - Needs `KLU_LIBRARY_DIR="$libdir"`, so CMake's `find_library` can find libraries from KLU

## Meson builds

BinaryBuilder supports also building with Meson.  Since this is going to be a cross-compilation, you have to specify a Meson cross file:

```sh
meson --cross-file="${MESON_TARGET_TOOLCHAIN}" --buildtype=release
```

After configuring the project with `meson`, you can then build and install it with

```
ninja -j${nproc}
ninja install
```

The wizard automatically suggests using Meson if the `meson.build` file is present.

Examples of builds performed with Meson include:

* [gdk-pixbuf](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/G/gdk_pixbuf/build_tarballs.jl#L22-L35):
  here meson uses platform-dependent options;
* [libepoxy](https://github.com/JuliaPackaging/Yggdrasil/blob/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/L/Libepoxy/build_tarballs.jl#L19-L25):
  this script modifies `c_args` in the Meson cross file in order to add an include directory;
* [xkbcommon](https://github.com/JuliaPackaging/Yggdrasil/blob/2f3638292c99fa6032634517f8a1aa8360d6fe8d/X/xkbcommon/build_tarballs.jl#L26-L30).

## Go builds

The Go toolchain provided by BinaryBuilder can be requested by adding `:go` to the `compilers` keyword argument to [`build_tarballs`](@ref): `compilers=[:c, :go]`, and a specific version of the toolchain can be selected by adding the `preferred_go_version` keyword argument to [`build_tarballs`](@ref).  Go-based packages can usually be built and installed with `go`:

```sh
go build -o ${bindir}
```

The Go toolchain provided by BinaryBuilder automatically selects the appropriate target.

Example of packages using Go:

* [pprof](https://github.com/JuliaPackaging/Yggdrasil/blob/ea43d07d264046e8c94a460907bba209a015c10f/P/pprof/build_tarballs.jl#L21-L22): it uses `go build` to compile the program and manually moves the executable to `${bindir}`.

## Rust builds

The Rust toolchain provided by BinaryBuilder can be requested by adding `:rust` to the `compilers` keyword argument to [`build_tarballs`](@ref): `compilers=[:c, :rust]`, and a specific version of the toolchain can be selected by adding the `preferred_rust_version` keyword argument to [`build_tarballs`](@ref).  Rust-based packages can usually be built with `cargo`:

```sh
cargo build --release
```

The Rust toolchain provided by BinaryBuilder automatically selects the appropriate target and number of parallel jobs to be used.  Note, however, that you may have to manually install the product in the `${prefix}`.  Read the installation instructions of the package in case they recommend a different build procedure.

Example of packages using Rust:

* [Tokei](https://github.com/JuliaPackaging/Yggdrasil/blob/ea43d07d264046e8c94a460907bba209a015c10f/T/Tokei/build_tarballs.jl#L14-L15): it uses `cargo build` to compile the program and manually moves the executable to `${bindir}`;
* [Librsvg](https://github.com/JuliaPackaging/Yggdrasil/blob/ea43d07d264046e8c94a460907bba209a015c10f/L/Librsvg/build_tarballs.jl#L35-L45): it uses a build system based on Autoconf which would internally call `cargo build`, but the user has to follow the `./configure` + `make` + `make install` sequence.


!!! warn

	The Rust toolchain currently used does not work with the `i686-w64-mingw32` (32-bit Windows) platform.

 ## C builds

 If your library has no build system like Make, CMake, Meson, or Autoconf, you may need to use the C compiler directly.  The C compiler is stored in the `CC` environment variable, and you can direct output to `libdir` (shared libraries) and `bindir` (executables).
As a high-level example:

 ```sh
# this assumes you are operating out of a Git source named `hello`
# adjust your `cd` appropriately
cd $WORKSPACE/srcdir/hello 
mkdir -p ${libdir}                                         # make sure the libdir is instantiated
${CC} -shared -o ${libdir}/libhello.${dlext} -fPIC hello.c # compile the library, save to `libdir`
```

This is simply compiling a single shared library, `libhello`, from `hello.c`.

## C++ builds

Similarly to C builds, sometimes your C++ libraries will not have a build system associated with them.  The C++ compiler is stored in the `CXX` environment variable.
As a high-level example:

```sh
# this assumes you are operating out of a Git source named `hello`
# adjust your `cd` appropriately
cd $WORKSPACE/srcdir/hello
mkdir -p ${libdir}
$CXX -shared -std=c++11 -O3 -fPIC -o ${libdir}/libhello.${dlext} src/hello.cpp # you may want to edit the `std` flag, for example
```

This is simply compiling a single shared library, `libhello`, from `hello.cpp`.

## Editing files in the wizard

In the wizard, the `vim` editor is available for editing files. But, it doesn't leave any record in the build script. One generally needs to provide patch files or use something like `sed`. If a file needs patching, we suggest using `git` to add the entire worktree to a new repo, make the changes you need, then use `git diff -p` to output a patch that can be included alongside your build recipe.

You can include local files like patches very easily by placing them within a `bundled/patches` nested directory, and then providing `"./bundled"` as one of the `sources` for your build.  See, for example, [`OpenBLAS`](https://github.com/JuliaPackaging/Yggdrasil/tree/8d5a27e24016c0ff2eae379f15dca17e79fd4be4/O/OpenBLAS/OpenBLAS%400.3.13).

## Automatic environment variables

The following environment variables are automatically set in the build environment and should be used to build the project.  Occasionally, you may need to tweak them (e.g., when [Using GCC on macOS and FreeBSD](@ref)).

* `CC`: the C cross compiler
* `CXX`: the C++ cross compiler
* `FC`: the Fortran cross compiler

The above variables point to utilities for the target environment.  To reference the utilities for the host environment either prepend `HOST` or append `_HOST`.  For example, `HOSTCC` and `CC_HOST` point to the native C compiler.

These are other environment variables that you may occasionally need to set during a build

* `CFLAGS`: options for the C compiler
* `CXXFLAGS`: options for the C++ compiler
* `CPPFLAGS`: options for the C pre-processor
* `LDFLAGS`: options for the linker
* `PKG_CONFIG_PATH`: a colon-separated list of directories to search for `.pc` files
* `PKG_CONFIG_SYSROOT_DIR`: modifies `-I` and `-L` to use the directories located in target sysroot

The following variables are useful to control the build script over different target systems, but are not intended to be modified by the users:

* `prefix`: the path to the top-directory of where all the products should be installed.  This will be the top-directory of the generated tarball
* `libdir`: the path to the directory where the shared libraries should be installed.  This is `${prefix}/bin` when building for Windows, `${prefix}/lib` for all other platforms
* `bindir`: the path to the directory where the executables should be installed.  This is equivalent to `${prefix}/bin`
* `includedir`: the path to the directory where the header files should be installed.  This is equivalent to `${prefix}/include`
* similar variables, with analogous meaning, exist for the host prefix (where [`HostBuildDependency`](@ref) are installed): `${host_prefix}`, `${host_bindir}`, `${host_libdir}`, `${host_includedir}`
* `target`: the target platform
* `bb_full_target`: the full target platform, containing things like libstdc++ string ABI platform tags, and libgfortran version
* `MACHTYPE`: the triplet of the host platform
* `nproc`: the number of processors of the host machine, useful for parallel building (e.g., `make -j${nproc}`)
* `nbits`: number of bits of the target architecture (usually it is either 32 or 64)
* `proc_family`: target processor family (e.g., "intel", "power", or "arm")
* `dlext`: extension of the shared library on the target system.  It is "dll" for Windows, "dylib" for macOS, and "so" for the other Unix systems
* `exeext`: extension of the executable on the target system, including the dot if present.  It is ".exe" for Windows and the empty string "" for all the other target platforms
* `SRC_NAME`: name of the project being built

## Using GCC on macOS and FreeBSD

For these target systems Clang is the default compiler, however some programs may not be compatible with Clang.

For programs built with CMake (see the [CMake build](#CMake-builds-1) section) you can use the GCC toolchain file that is in `${CMAKE_TARGET_TOOLCHAIN%.*}_gcc.cmake`.

For programs built with Meson (see the [Meson build](#Meson-builds-1) section) you can use the GCC toolchain file that is in `${MESON_TARGET_TOOLCHAIN%.*}_gcc.meson`.

If the project that you want to build uses the GNU Build System (also known as the Autotools), there isn't an automatic switch to use GCC, but you have to set the appropriate variables.  For example, this setting can be used to build most C/C++ programs with GCC for FreeBSD and macOS:
```sh
if [[ "${target}" == *-freebsd* ]] || [[ "${target}" == *-apple-* ]]; then
    CC=gcc
    CXX=g++
fi
```

## [Linking to BLAS/LAPACK libraries](@id link-blas)

Many numerical libraries link to [BLAS](https://en.wikipedia.org/wiki/Basic_Linear_Algebra_Subprograms)/[LAPACK](https://en.wikipedia.org/wiki/LAPACK) libraries to execute optimised linear algebra routines.
It is important to understand that the elements of the arrays manipulated by these libraries can be indexed by either 32-bit integer numbers ([LP64](https://en.wikipedia.org/wiki/64-bit_computing#64-bit_data_models)), or 64-bit integers (ILP64).
For example, Julia itself employs BLAS libraries for linear algebra, and it expects ILP64 model on 64-bit platforms (e.g. the `x86_64` and `aarch64` architectures) and LP64 on LP64 on 32-bit platforms (e.g. the `i686` and `armv7l` architectures).
Furthermore, Julia comes by default with [`libblastrampoline`](https://github.com/JuliaLinearAlgebra/libblastrampoline), a library which doesn't implement itself any BLAS/LAPACK routine but it forwards all BLAS/LAPACK function calls to another library (by default OpenBLAS) which can be designated at runtime, allowing you to easily switch between different backends if needed.
`libblastrampoline` provides both ILP64 and LP64 interfaces on 64-bit platforms, in the former case BLAS function calls are expected to have the `_64` suffix to the standard BLAS names.

If in your build you need to use a package to a BLAS/LAPACK library you have the following options:

* use ILP64 interface on 64-bit systems and LP64 interface on 32-bit ones, just like Julia itself.
  In this case, when targeting 64-bit systems you will need to make sure all BLAS/LAPACK function calls in the package you want to build will follow the expected naming convention of using the `_64` suffix, something which most packages would not do automatically.
  The build systems of some packages (e.g. [`OpenBLAS`](https://github.com/JuliaPackaging/Yggdrasil/blob/b7f5e3c48f292078bbed4c9fdad071da7875c0bc/O/OpenBLAS/common.jl#L125) and [`SuiteSparse`](https://github.com/JuliaPackaging/Yggdrasil/blob/master/S/SuiteSparse/SuiteSparse%407/build_tarballs.jl#L30-L39)) provide this option out-of-the-box, but in most cases you will need to rename the symbols manually using the preprocessor, see for example the [`armadillo`](https://github.com/JuliaPackaging/Yggdrasil/blob/b7f5e3c48f292078bbed4c9fdad071da7875c0bc/A/armadillo/build_tarballs.jl#L29-L41) recipe.
  If you are ready to use ILP64 interface on 64-bit systems, you can choose different libraries to link to:
  - `libblastrampoline`, using the `libblastrampoline_jll` dependency.
    This is the recommended solution, as it is also what is used by Julia itself, it does not introduce new dependencies, a default backing BLAS/LAPACK is always provided, and also the package you are building can take advantage of `libblastrampoline`'s mechanism to switch between different BLAS/LAPACK backend for optimal performance.
    A couple of caveats to be aware of:
      * for compatibility reasons it's recommended to use
        ```julia
        Dependency("libblastrampoline_jll"; compat="5.4.0")
        ```
        as dependency and also pass `julia_compat="1.9"` as keyword argument to the [`build_tarballs`](@ref) function
      * to link to `libblastrampoline` you should use `-lblastrampoline` when targeting Unix systems, and `-lblastrampoline-5` (`5` being the major version of the library) when targeting Windows.
  - link directly to other libraries which provide the ILP64 interface on 64-bit systems and the LP64 interface on 32-bit systems, like `OpenBLAS_jll` (what is used by default by julia to back `libblastrampoline`), but once you made the effort to respect the ILP64 interface linking to `libbastrampoline` may be more convenient
* always use LP64 interface, also on 64-bit systems.
  This may be a simpler option if renamining the BLAS/LAPACK symbols is too cumbersome in your case.
  In terms of libraries to link to:
  - also in this case you can link to `libblastrampoline`, however you _must_ make sure an LP64 BLAS/LAPACK library is backing `libblastrampoline`, otherwise all BLAS/LAPACK calls from the library will result in hard-to-debug segmentation faults, because in this case Julia does not provided a default backing LP64 BLAS/LAPACK library on 64-bit systems
  - alternatively, you can use builds of BLAS/LAPACK libraries which always use LP64 interface also on 64-bit platforms, like the package `OpenBLAS32_jll`.

## Dependencies for the target system vs host system

BinaryBuilder provides a cross-compilation environment, which means that in general there is a distinction between the target platform (where the build binaries will eventually run) and the host platform (where compilation is currently happening).  In particular, inside the build environment in general you cannot run binary executables built for the target platform.

For a build to work there may be different kinds of dependencies, for example:

* binary libraries that the final product of the current build (binary executables or other libraries) will need to link to.  These libraries must have been built for the target platform.  You can install this type of dependency as [`Dependency`](@ref), which will also be a dependency of the generated JLL package.  This is the most common class of dependencies;
* binary libraries or non-binary executables (usually shell scripts that can actually be run inside the build environment) for the target platform that are exclusively needed during the build process, but not for the final product of the build to run on the target system.  You can install this type of dependency as [`BuildDependency`](@ref).  Remember they will _not_ be added as dependency of the generated JLL package;
* binary executables that are exclusively needed to be run during the build process.  They cannot generally have been built for the target platform, so they cannot be installed as `Dependency` or `BuildDependency`.  However you have two options:

  * if they are available in a JLL package for the `x86_64-linux-musl` platform, you can install them as [`HostBuildDependency`](@ref).  In order to keep binaries for the target platform separated from those for the host system, these dependencies will be installed under `${host_prefix}`, in particular executables will be present under `${host_bindir}` which is automatically added to the `${PATH}` environment variable;
  * if they are present in Alpine Linux repositories, you can install them with the system package manager [`apk`](https://wiki.alpinelinux.org/wiki/Alpine_Linux_package_management).

  Remember that this class of dependencies is built for the host platform: if the library you want to build for the target platform requires another binary library to link to, installing it as `HostBuildDependency` or with `apk` will not help.

You need to understand the build process of package you want to compile in order to know what of these classes a dependency belongs to.

## Installing the license file

Generated tarballs should come with the license of the library that you want to install.  If at the end of a successful build there is only one directory inside `${WORKSPACE}/srcdir`, BinaryBuilder will look into it for files with typical names for license (like `LICENSE`, `COPYRIGHT`, etc... with some combinations of extensions) and automatically install them to `${prefix}/share/licenses/${SRC_NAME}/`.  If in the final tarball there are no files in this directory a warning will be issued, to remind you to provide a license file.

If the license file is not automatically installed (for example because there is more than one directory in `${WORKSPACE}/srcdir` or because the file name doesn't match the expected pattern) you have to manually install the file.  In the build script you can use the `install_license` command.  See the [Utilities in the build environment](@ref utils_build_env) section below.

## [Utilities in the build environment](@id utils_build_env)

In addition to the standard Unix tools, in the build environment there are some extra commands provided by BinaryBuilder.  Here is a list of some of these commands:

* `atomic_patch`: utility to apply patches.  It is similar to the standard `patch`, but it fails gracefully when a patch cannot be applied:
  ```sh
  atomic_patch -p1 /path/to/file.patch
  ```
* `flagon`: utility to translate some compiler-flags to the one required on the current platform.  For example, to build a shared library from a static archive:
  ```sh
  cc -o "${libdir}/libfoo.${dlext}" -Wl,$(flagon --whole-archive) libfoo.a -Wl,$(flagon --no-whole-archive) -lm
  ```
  The currently supported flags are:
  * `--whole-archive`;
  * `--no-whole-archive`;
  * `--relative-rpath-link`.
* `install_license`: utility to install a file to `${prefix}/share/licenses/${SRC_NAME}`:
  ```sh
  install_license ${WORKSPACE}/srcdir/THIS_IS_THE_LICENSE.md
  ```
* `update_configure_scripts`: utility to update autoconfigure scripts.  Sometimes libraries come with out-of-date autoconfigure scripts (e.g., old `configure.sub` can't recognise `aarch64` platforms or systems using Musl C library).  Just run
  ```sh
  update_configure_scripts
  ```
  to get a newer version.  With the `--reconf` flag, it also runs `autoreconf -i -f` afterwards:
  ```sh
  update_configure_scripts --reconf
  ```
