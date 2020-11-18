using SnoopCompile

@snoopi_bot "BinaryBuilder" begin
    using BinaryBuilder
    # Do an actual build
    products = Product[
        ExecutableProduct("hello_world_c", :hello_world_c),
        ExecutableProduct("hello_world_cxx", :hello_world_cxx),
        ExecutableProduct("hello_world_fortran", :hello_world_fortran),
        ExecutableProduct("hello_world_go", :hello_world_go),
        ExecutableProduct("hello_world_rust", :hello_world_rust),
    ]

    # First, do the build, but only output the meta json, since we definitely want that to be fast
    build_tarballs(
        ["--meta-json=/dev/null"],
        "testsuite",
        v"1.0.0",
        # No sources
        DirectorySource[],
        # Build the test suite, install the binaries into our prefix's `bin`
        raw"""
        # Build testsuite
        make -j${nproc} -sC /usr/share/testsuite install
        # Install fake license just to silence the warning
        install_license /usr/share/licenses/MIT
        """,
        [HostPlatform()],
        products,
        # No dependencies
        Dependency[];
    )

    # Next, actually do a build, since we want that to be fast too.
    build_tarballs(
        ["--verbose"],
        "testsuite",
        v"1.0.0",
        # Add some sources, so that we actually download them
        [
            ArchiveSource("https://github.com/staticfloat/small_bin/raw/master/socrates.tar.gz",
                          "e65d2f13f2085f2c279830e863292312a72930fee5ba3c792b14c33ce5c5cc58"),
            DirectorySource("src"),
        ],
        # Build the test suite, install the binaries into our prefix's `bin`
        raw"""
        # Build testsuite
        make -j${nproc} -sC /usr/share/testsuite install
        # Install fake license just to silence the warning
        install_license /usr/share/licenses/MIT
        """,
        [HostPlatform()],
        products,
        # Add a dependency on Zlib_jll, our favorite scapegoat
        Dependency[
            Dependency("Zlib_jll"),
        ];
        compilers=[:c, :rust, :go],
    )

    rm("build"; recursive=true, force=true)
    rm("products"; recursive=true, force=true)
end
