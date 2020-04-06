# Tricksy Gotchas

There are a plethora of gotchas when it comes to binary compilation and distribution that must be appropriately addressed, or the binaries will only work on certain machines and not others.  Here is an incomplete list of things that `BinaryBuilder.jl` takes care of for you:

* Uniform compiler interface
No need to worry about invoking compilers through weird names; just run `gcc` within the proper environment and you'll get the appropriate cross-compiler.  Triplet-prefixed names (such as `x86_64-linux-gnu-gcc`) are, of course, also available, and the same version of `gcc`, `g++` and `gfortran` is used across all platforms.

* `glibc` versioning
On Linux platforms that use `glibc` as the C runtime library (at the time of writing, this is the great majority of most desktop and server distros), it is necessary to compile code against a version of `glibc` that is _older_ than any glibc version it will be run on.  E.g. if your code is compiled against `glibc v2.5`, it will run on `glibc v2.6`, but it will not run on `glibc v2.4`.  Therefore, to maximize compatibility, all code should be compiled against as old a version of `glibc` as possible.

* `gfortran` versioning
When compiling FORTRAN code, the `gfortran` compiler has broken ABI compatibility in the 6.X -> 7.X transition, and the 7.X -> 8.X transition.  This means that code built with `gfortran` 6.X cannot be linked against code built with `gfortran` 7.X.  We therefore compile all `gfortran` code against multiple different `gfortran` versions, then at runtime decide which to download based upon the currently running process' existing linkage.

* `cxx11` string ABI
When switching from the `cxx03` standard to `cxx11` in GCC 5, the internal layout of `std::string` objects changed.  This causes incompatibility between C++ code passing strings back and forth across the public interface if they are not built with the same C++ string ABI.  We therefore detect when `std::string` objects are being passed around, and warn that you need to build two different versions, one with `cxx03`-style strings (doable by setting `-D_GLIBCXX_USE_CXX11_ABI=0` for newer GCC versions) and one with `cxx11`-style strings.

* Library Dependencies
A large source of problems in binary distribution is improper library linkage.  When building a binary object that depends upon another binary object, some operating systems (such as macOS) bake the absolute path to the dependee library into the dependent, whereas others rely on the library being present within a default search path.  `BinaryBuilder.jl` takes care of this by automatically discovering these errors and fixing them by using the `RPATH`/`RUNPATH` semantics of whichever platform it is targeting.  Note that this is technically a build system error, and although we will fix it automatically, it will raise a nice yellow warning during build prefix audit time.

* Embedded absolute paths
Similar to library dependencies, plain files (and even symlinks) can have the absolute location of files embedded within them.  `BinaryBuilder.jl` will automatically transform symlinks to files within the build prefix to be the equivalent relative path, and will alert you if any files within the prefix contain absolute paths to the build prefix within them.  While the latter cannot be automatically fixed, it may help in tracking down problems with the software later on.

* Instruction Set Differences
When compiling for architectures that have evolved over time (such as `x86_64`), it is important to target the correct instruction set, otherwise a binary may contain instructions that will run on the computer it was compiled on, but will fail rather ungracefully when run on a machine that does not have as new a processor.  `BinaryBuilder.jl` will automatically disassemble every built binary object and inspect the instructions used, warning the user if a binary is found that does not conform to the agreed-upon minimum instruction set architecture.  It will also notice if the binary contains a `cpuid` instruction, which is a good sign that the binary is aware of this issue and will internally switch itself to use only available instructions.