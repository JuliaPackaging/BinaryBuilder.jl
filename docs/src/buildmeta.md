# buildmeta

This document contains the overview of the `BuildMeta` API added in BinaryBuilder in September of 2021.

## Key Datastructures

A `BuildConfig` represents a single build, and results in a single `BuildResult`.  A set of these together, (all with the same name) can be passed to a `ExtractConfig`, which will result in a `ExtractResult`.  Multiple `PackageResult`s (all with the same name) can then be passed to a `PackageConfig`, which will generate a `PackageResult`.

By default, calling `build_tarballs!()` will generate a very simple topology: A set of `BuildConfig`s, one per platform, each being passed to an identical `ExtractConfig`, and all being collected into a single `PackageConfig`.

We list here some slightly more complex examples:

    - **Build once, package multiple times**: packages such as `libLLVM`, `LLVM` and `Clang` can be built with a single `BuildConfig`, but with multiple `ExtractConfig`s feeding from that single build, then each `ExtractConfig` being fed to its own `PackageConfig`.

    - **Cross-platform packaging differences**: Occasionally, we wrap projects that have large differences between platforms.  If the very existence of certain products changes between platforms, users can group some builds under one `ExtractConfig` (with its associated list of products) and other builds under another.

    - 
