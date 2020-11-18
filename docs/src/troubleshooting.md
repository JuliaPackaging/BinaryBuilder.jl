# Build Troubleshooting

This page collects some known build errors and trick how to fix them.

*If you have additional tips, please submit a PR with suggestions.*

## All platforms

### Header files of the dependencies can't be found

Sometimes the build system can't find the header files of the dependencies, even if they're properly installed.  When this happens, you have to inform the C/C++ preprocessor where the files are.

For example, if the project uses Autotools you can set the `CPPFLAGS` environment variable:

```sh
export CPPFLAGS="-I${prefix}/include"
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nprocs}
make install
```

See for example [Cairo](https://github.com/JuliaPackaging/Yggdrasil/blob/9a1ae803823e0dba7628bc71ff794d0c79e39c95/C/Cairo/build_tarballs.jl#L16-L17) build script.

If instead the project uses CMake you'll need to use a different environment variable, since CMake ignores `CPPFLAGS`.  If the compiler that can't find the header file is the C one, you need to add the path to the `CFLAGS` variable (e.g., `CFLAGS="-I${prefix}/include"`), in case it's the C++ one you have to set the `CXXFLAGS` variable (e.g., `CXXFLAGS="-I${prefix}/include"`).

### Libraries of the dependencies can't be found

Like in the section above, it may happen that the build system fails to find the libraries of the dependencies, even when they're installed to the right place.  In these case, you have to inform the linker where the libraries are by setting the `LDFLAGS` environment variable:

```sh
export LDFLAGS="-L${libdir}"
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nprocs}
make install
```

See for example [libwebp](https://github.com/JuliaPackaging/Yggdrasil/blob/9a1ae803823e0dba7628bc71ff794d0c79e39c95/L/libwebp/build_tarballs.jl#L19-L21) build script (in this case this was needed only when building for FreeBSD).

### Old Autoconf helper scripts

Packages using Autoconf come with some helper scripts -- like `config.sub` and `config.guess` -- that the upstream developers need to keep up-to-date in order to get the latest improvements.  Some packages ship very old copies of these scripts, that for example don't know about the Musl C library.  In that case, after running `./configure` you may get an error like

```
checking build system type... Invalid configuration `x86_64-linux-musl': system `musl' not recognized
configure: error: /bin/sh ./config.sub x86_64-linux-musl failed
```

The `BinaryBuilder` environment provides the utility [`update_configure_scripts`](https://juliapackaging.github.io/BinaryBuilder.jl/dev/build_tips/#Utilities-in-the-build-environment-1) to automatically update these scripts, call it before `./configure`:

```sh
update_configure_scripts
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nproc}
make install
```

### Building with an old GCC version a library that has dependencies built with newer GCC versions

The keyword argument `preferred_gcc_version` to the `build_tarballs` function allows you to select a newer compiler to build a library, if needed.  Pure C libraries have good compatibility so that a library built with a newer compiler should be able to run on a system using an older GCC version without problems.  However, keep in mind that each GCC version in `BinaryBuilder.jl` comes bundled with a specific version of binutils  -- which provides the `ld` linker -- see [this table](https://github.com/JuliaPackaging/Yggdrasil/blob/master/RootFS.md#compiler-shards).

`ld` is quite picky and a given version of this tool doesn't like to link a library linked with a newer version: this means that if you build a library with, say, GCC v6, you'll need to build all libraries depending on it with GCC >= v6.  If you fail to do so, you'll get a cryptic error like this:

```
/opt/x86_64-linux-gnu/bin/../lib/gcc/x86_64-linux-gnu/4.8.5/../../../../x86_64-linux-gnu/bin/ld: /workspace/destdir/lib/libvpx.a(vp8_cx_iface.c.o): unrecognized relocation (0x2a) in section `.text'
/opt/x86_64-linux-gnu/bin/../lib/gcc/x86_64-linux-gnu/4.8.5/../../../../x86_64-linux-gnu/bin/ld: final link failed: Bad value
```

The solution is to build the downstream libraries with at least the maximum of the GCC versions used by the dependencies:

```julia
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; preferred_gcc_version=v"8")
```

For instance, FFMPEG [has to be built with GCC v8](https://github.com/JuliaPackaging/Yggdrasil/blob/9a1ae803823e0dba7628bc71ff794d0c79e39c95/F/FFMPEG/build_tarballs.jl#L140) because LibVPX [requires GCC v8](https://github.com/giordano/Yggdrasil/blob/2b13acd75081bc8105685602fcad175296264243/L/LibVPX/build_tarballs.jl).

Generally speaking, we try to build with the as old as possible version of GCC (v4.8.5 being the oldest one currently available), for maximum compatibility.

### Running foreign executables

The build environment provided by `BinaryBuilder` is a `x86_64-linux-musl`, and it can run executables for the following platforms: `x86_64-linux-musl`, `x86_64-linux-gnu`, `i686-linux-gnu`.  For all other platforms, if the build system tries to run a foreign executable you'll get an error, usually something like

```
./foreign.exe: line 1: ELF��
                       @@xG@8@@@@@@���@�@@����A�A����A�A���@�@: not found
./foreign.exe: line 1: syntax error: unexpected end of file (expecting ")")
```

This is one of worst cases when cross-compiling, and there isn't a simple solution.  You have to look into the build process to see if running the executable can be skipped (see for example the patch to not run `dot` in [#351](https://github.com/JuliaPackaging/Yggdrasil/pull/351)), or replaced by something else.  If the executable is a compile-time only utility, try to build it with the native compiler (see for example the patch to build a native `mkdefs` in [#351](https://github.com/JuliaPackaging/Yggdrasil/pull/351))

### Multiple library names for different platforms
Since some projects use different libnames for different platforms, when passing multiple libnames to `LibraryProduct`, you can use `parse_dl_name_version` to query the libname, for example:  

```
julia> using Base.BinaryPlatforms

julia> parse_dl_name_version("sfml-audio-2.dll", "windows")[1]
"sfml-audio"
```

## PowerPC Linux

### Shared library not built

Sometimes the shared library for `powerpc64le-linux-gnu` is not built after a successful compilation, and audit fails because only the static library has been compiled.  If the build uses Autotools, this most likely happens because the `configure` script was generated with a very old version of Autotools, which didn't know how to build shared libraries for this system.  The trick here is to regenerate the `configure` script with `autoreconf`:

```sh
autoreconf -vi
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nproc}
make install
```

See for example the builder for [Giflib](https://github.com/JuliaPackaging/Yggdrasil/blob/78fb3a7b4d00f3bc7fd2b1bcd24e96d6f31d6c4b/G/Giflib/build_tarballs.jl).  If you need to regenerate `configure`, you'll probably need to run [`update_configure_scripts`](https://juliapackaging.github.io/BinaryBuilder.jl/dev/build_tips/#Utilities-in-the-build-environment-1) to make other platforms work as well.

## FreeBSD

### ```undefined reference to `backtrace_symbols'```

If compilation fails because of the following errors

```
undefined reference to `backtrace_symbols'
undefined reference to `backtrace'
```

then you need to link to `execinfo`:

```sh
if [[ "${target}" == *-freebsd* ]]; then
    export LDFLAGS="-lexecinfo"
fi
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nprocs}
make install
```

See for example [#354](https://github.com/JuliaPackaging/Yggdrasil/pull/354) and [#982](https://github.com/JuliaPackaging/Yggdrasil/pull/982).

## Windows

### Libtool refuses to build shared library because of undefined symbols

When building for Windows, sometimes libtool refuses to build the shared library because of undefined symbols.  When this happens, compilation is successful but BinaryBuilder's audit can't find the expected `LibraryProduct`s.

In the log of compilation you can usually find messages like

```
libtool: warning: undefined symbols not allowed in i686-w64-mingw32 shared libraries; building static only
```

or

```
libtool:   error: can't build i686-w64-mingw32 shared library unless -no-undefined is specified
```

In these cases you have to pass the `-no-undefined` option to the linker, as explicitly suggested by the second message.

A proper fix requires to add the `-no-undefined` flag to the `LDFLAGS` of the corresponding libtool archive in the `Makefile.am` file.  For example, this is done in [`CALCEPH`](https://github.com/JuliaPackaging/Yggdrasil/blob/d1e5159beef7fcf8c631e893f62925ca5bd54bec/C/CALCEPH/build_tarballs.jl#L19), [`ERFA`](https://github.com/JuliaPackaging/Yggdrasil/blob/d1e5159beef7fcf8c631e893f62925ca5bd54bec/E/ERFA/build_tarballs.jl#L17), and [`libsharp2`](https://github.com/JuliaPackaging/Yggdrasil/blob/d1e5159beef7fcf8c631e893f62925ca5bd54bec/L/libsharp2/build_tarballs.jl#L19).

A quick and dirty alternative to patching the `Makefile.am` file is to pass `LDFLAGS=-no-undefined` only to `make`:

```sh
FLAGS=()
if [[ "${target}" == *-mingw* ]]; then
    FLAGS+=(LDFLAGS="-no-undefined")
fi
./configure --prefix=${prefix} --build=${MACHTYPE} --host=${target}
make -j${nprocs} "${FLAGS[@]}"
make install
```

Note that setting `LDFLAGS=-no-undefined` before `./configure` would make this fail because it would run a command like `cc -no-undefined conftest.c`, which upsets the compiler).  See for example [#170](https://github.com/JuliaPackaging/Yggdrasil/pull/170), [#354](https://github.com/JuliaPackaging/Yggdrasil/pull/354).
