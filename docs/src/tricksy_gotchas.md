# Tricksy Gotchas

There is a plethora of gotchas when it comes to binary compilation and distribution that must be appropriately addressed, or the binaries will only work on certain machines and not others.  Here is an incomplete list of things that this package takes care of for you:

* Uniform compiler interface
No need to worry about invoking compilers through weird names; just run `gcc` within the proper environment and you'll get the appropriate cross-compiler.  Triplet-prefixed names (such as `x86_64-linux-gnu-gcc`) are, of course, also available, and the same version of `gcc`, `g++` and `gfortran` is used across all platforms.

* `glibc` versioning
On Linux platforms that use `glibc` as the C runtime library (at the time of writing, this is the great majority of most desktop and server distros), it is necessary to compile code against a version of `glibc` that is _older_ than any glibc version it will be run on.  E.g. if your code is compiled against `glibc v2.5`, it will run on `glibc v2.6`, but it will not run on `glibc v2.4`.  Therefore, to maximize compability, all code should be compiled against as old a version of `glibc` as possible.

* Library Dependencies
A large source of problems in binary distribution is improper library linkage.  When building a binary object that depends upon another binary object, some operating systems (such as macOS) bake the absolute path to the dependee library into the dependent, whereas others rely on the library being present within a default search path.  BinaryBuilder.jl takes care of this by automatically discovering these errors and fixing them by using the `RPATH`/`RUNPATH` semantics of whichever platform it is targeting.  Note that this is technically a build system error, and although we will fix it automatically, it will raise a nice yellow warning during build prefix audit time.