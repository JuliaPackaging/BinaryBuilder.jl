using BinaryBuilder.Auditor
using BinaryBuilder.Auditor: compatible_marchs

# Tests for our auditing infrastructure

@testset "Auditor - cppfilt" begin
    # We take some known x86_64-linux-gnu symbols and pass them through c++filt
    mangled_symbol_names = [
        "_ZNKSt7__cxx1110_List_baseIiSaIiEE13_M_node_countEv",
        "_ZNKSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE6lengthEv@@GLIBCXX_3.4.21",
        "_Z10my_listlenNSt7__cxx114listIiSaIiEEE",
        "_ZNKSt7__cxx114listIiSaIiEE4sizeEv",
    ]
    unmangled_symbol_names = Auditor.cppfilt(mangled_symbol_names, Platform("x86_64", "linux"))
    @test all(unmangled_symbol_names .== [
        "std::__cxx11::_List_base<int, std::allocator<int> >::_M_node_count() const",
        "std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::length() const@@GLIBCXX_3.4.21",
        "my_listlen(std::__cxx11::list<int, std::allocator<int> >)",
        "std::__cxx11::list<int, std::allocator<int> >::size() const",
    ])
end

@testset "Auditor - ISA tests" begin
    @test compatible_marchs(Platform("x86_64", "linux")) == ["x86_64"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="x86_64")) == ["x86_64"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx")) == ["x86_64", "avx"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx2")) == ["x86_64", "avx", "avx2"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx512")) == ["x86_64", "avx", "avx2", "avx512"]
    @test compatible_marchs(Platform("armv7l", "linux")) == ["armv7l"]
    @test compatible_marchs(Platform("i686", "linux"; march="prescott")) == ["i686", "prescott"]
    @test compatible_marchs(Platform("aarch64", "linux"; march="armv8_1")) == ["armv8_0", "armv8_1"]

    product = ExecutableProduct("main", :main)

    # The microarchitecture of the product doesn't match the target architecture: complain!
    mktempdir() do build_path
        platform = Platform("x86_64", "linux"; march="avx")
        build_output_meta = nothing
        @test_logs (:info, "Building for x86_64-linux-gnu-march+avx") (:warn, r"is avx512, not avx as desired.$") match_mode=:any begin
            build_output_meta = autobuild(
                build_path,
                "isa_tests",
                v"1.0.0",
                [DirectorySource(build_tests_dir)],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                cd ${WORKSPACE}/srcdir/isa_tests
                make -j${nproc} CFLAGS="-march=skylake-avx512 -mtune=skylake-avx512" install
                install_license /usr/include/ltdl.h
                """,
                # Build for our platform
                [platform],
                # Ensure our executable products are built
                [product],
                # No dependencies
                Dependency[];
                preferred_gcc_version=v"6",
                lock_microarchitecture=false,
            )

            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            prefix = Prefix(testdir)

            # Run ISA test
            readmeta(locate(product, prefix)) do oh
                detected_isa = Auditor.analyze_instruction_set(oh, platform; verbose=true)
                @test detected_isa == "avx512"
            end
        end
    end

    # The instruction set of the product is compatible with the target
    # architecture, but it's lower than desired: issue a gentle warning
    mktempdir() do build_path
        platform = Platform("x86_64", "linux"; march="avx512")
        build_output_meta = nothing
        @test_logs (:info, "Building for x86_64-linux-gnu-march+avx512") (:warn, r"is avx, not avx512 as desired. You may be missing some optimization flags during compilation.$") match_mode=:any begin
            build_output_meta = autobuild(
                build_path,
                "isa_tests",
                v"1.0.0",
                [DirectorySource(build_tests_dir)],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                cd ${WORKSPACE}/srcdir/isa_tests
                make -j${nproc} CFLAGS="-march=sandybridge -mtune=sandybridge" install
                install_license /usr/include/ltdl.h
                """,
                # Build for our platform
                [platform],
                # Ensure our executable products are built
                [product],
                # No dependencies
                Dependency[];
                preferred_gcc_version=v"6",
                lock_microarchitecture=false,
            )

            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            prefix = Prefix(testdir)

            # Run ISA test
            readmeta(locate(product, prefix)) do oh
                detected_march = Auditor.analyze_instruction_set(oh, platform; verbose=true)
                @test detected_march == "avx"
            end
        end
    end

    # The microarchitecture of the product matches the target architecture: no warnings!
    for march in ("x86_64", "avx", "avx2", "avx512")
        mktempdir() do build_path
            platform = Platform("x86_64", "linux"; march=march)
            build_output_meta = nothing
            @test_logs (:info, "Building for x86_64-linux-gnu-march+$(march)") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "isa_tests",
                    v"1.0.0",
                    [DirectorySource(build_tests_dir)],
                    # Build the test suite, install the binaries into our prefix's `bin`
                    raw"""
                    cd ${WORKSPACE}/srcdir/isa_tests
                    make -j${nproc} install
                    install_license /usr/include/ltdl.h
                    """,
                    # Build for our platform
                    [platform],
                    # Ensure our executable products are built
                    [product],
                    # No dependencies
                    Dependency[];
                    # Use a recent version of GCC to make sure we can detect the
                    # ISA accurately even with new optimizations
                    preferred_gcc_version=v"8"
                )
            end

            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            prefix = Prefix(testdir)

            # Run ISA test
            readmeta(locate(product, prefix)) do oh
                detected_march = Auditor.analyze_instruction_set(oh, platform; verbose=true)
                if march == "avx2"
                    # Detecting the ISA isn't 100% reliable and it's even less
                    # accurate when looking for AVX2 features
                    @test_broken march == detected_march
                else
                    @test march == detected_march
                end
            end
        end
    end
end

@testset "Auditor - cxxabi selection" begin
    libcxxstringabi_test = LibraryProduct("libcxxstringabi_test", :libcxxstringabi_test)

    # Factor the autobuild() out
    function do_build(build_path, script, platform, gcc_version)
        autobuild(
            build_path,
            "libcxxstringabi_test",
            v"1.0.0",
            # Copy in the build_tests sources
            [DirectorySource(build_tests_dir)],
            script,
            # Build for this platform
            [platform],
            # The products we expect to be build
            [libcxxstringabi_test],
            # No depenedencies
            Dependency[];
            preferred_gcc_version=gcc_version
        )
    end

    for platform in (Platform("x86_64", "linux"; cxxstring_abi="cxx03"),
                     Platform("x86_64", "linux"; cxxstring_abi="cxx11"))
        # Look across multiple gcc versions; there can be tricksy interactions here
        for gcc_version in (v"4", v"6", v"9")
            # Do each build within a separate temporary directory
            mktempdir() do build_path
                script = raw"""
                    cd ${WORKSPACE}/srcdir/cxxstringabi_tests
                    make install
                    install_license /usr/share/licenses/libuv/LICENSE
                """
                build_output_meta = do_build(build_path, script, platform, gcc_version)
                # Extract our platform's build
                @test haskey(build_output_meta, platform)
                tarball_path, tarball_hash = build_output_meta[platform][1:2]
                @test isfile(tarball_path)

                # Unpack it somewhere else
                @test verify(tarball_path, tarball_hash)
                testdir = joinpath(build_path, "testdir")
                mkdir(testdir)
                unpack(tarball_path, testdir)
                prefix = Prefix(testdir)

                # Ensure that the library detects as the correct cxxstring_abi:
                readmeta(locate(libcxxstringabi_test, prefix)) do oh
                    detected_cxxstring_abi = Auditor.detect_cxxstring_abi(oh, platform)
                    @test detected_cxxstring_abi == cxxstring_abi(platform)
                end

                # Explicitly test cxx string abi mismatches
                if gcc_version > v"4"
                    script = """
                        mkdir -p \${libdir}
                        /opt/\${target}/bin/\${target}-g++ -fPIC \\
                            -D_GLIBCXX_USE_CXX11_ABI=$(cxxstring_abi(platform) == "cxx03" ? "1" : "0") \\
                            -o \${libdir}/libcxxstringabi_test.\${dlext} \\
                            -shared \${WORKSPACE}/srcdir/cxxstringabi_tests/lib.cc
                        install_license /usr/share/licenses/libuv/LICENSE
                    """
                    @test_logs (:warn, r"ignoring our choice of compiler") match_mode=:any begin
                        do_build(build_path, script, platform, gcc_version)
                    end
                end
            end
        end
    end

    # Explicitly test not setting a cxx string abi at all
    script = raw"""
        cd ${WORKSPACE}/srcdir/cxxstringabi_tests
        make install
        install_license /usr/share/licenses/libuv/LICENSE
    """
    platform = Platform("x86_64", "linux")
    mktempdir() do build_path
        @test_logs (:warn, r"contains std::string values") match_mode=:any begin
            do_build(build_path, script, platform, v"6")
        end
    end
end


@testset "Auditor - .dll moving" begin
    for platform in [Platform("x86_64", "windows")]
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:warn, r"lib/libfoo.dll should be in `bin`") (:warn, r"Simple buildsystem detected") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "dll_moving",
                    v"1.0.0",
                    GitSource[],
                    # Install a .dll into lib
                    raw"""
                    mkdir -p ${prefix}/lib
                    cc -o ${prefix}/lib/libfoo.${dlext} -shared /usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
                    install_license /usr/include/ltdl.h
                    """,
                    # Build for our platform
                    [platform],
                    # Ensure our executable products are built
                    Product[LibraryProduct("libfoo", :libfoo)],
                    # No dependencies
                    Dependency[]
                )
            end

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Test that `libfoo.dll` gets moved to `bin` if it's a windows
            contents = list_tarball_files(tarball_path)
            @test "bin/libfoo.$(platform_dlext(platform))" in contents
        end
    end
end

@testset "Auditor - .dylib identity mismatch" begin
    mktempdir() do build_path
        no_id = LibraryProduct("no_id", :no_id)
        abs_id = LibraryProduct("abs_id", :wrong_id)
        wrong_id = LibraryProduct("wrong_id", :wrong_id)
        right_id = LibraryProduct("right_id", :wrong_id)
        platform = Platform("x86_64", "macos")

        build_output_meta = autobuild(
            build_path,
            "dll_moving",
            v"1.0.0",
            FileSource[],
            # Intsall a .dll into lib
            raw"""
            mkdir -p ${prefix}/lib
            SRC=/usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
            cc -o ${libdir}/no_id.${dlext} -shared $SRC
            cc -o ${libdir}/abs_id.${dlext} -Wl,-install_name,${libdir}/abs_id.${dlext} -shared $SRC
            cc -o ${libdir}/wrong_id.${dlext} -Wl,-install_name,@rpath/totally_different.${dlext} -shared $SRC
            cc -o ${libdir}/right_id.${dlext} -Wl,-install_name,@rpath/right_id.${dlext} -shared $SRC
            install_license /usr/include/ltdl.h
            """,
            # Build for MacOS
            [platform],
            # Ensure our executable products are built
            Product[no_id, abs_id, wrong_id, right_id],
            # No dependencies
            Dependency[],
        )

        # Extract our platform's build
        @test haskey(build_output_meta, platform)
        tarball_path, tarball_hash = build_output_meta[platform][1:2]
        @test isfile(tarball_path)

        # Unpack it somewhere else
        @test verify(tarball_path, tarball_hash)
        testdir = joinpath(build_path, "testdir")
        mkdir(testdir)
        unpack(tarball_path, testdir)
        prefix = Prefix(testdir)

        # Helper to extract the dylib id of a path
        function get_dylib_id(path)
            return readmeta(path) do oh
                dylib_id_lcs = [lc for lc in MachOLoadCmds(oh) if isa(lc, MachOIdDylibCmd)]
                @test !isempty(dylib_id_lcs)
                return dylib_name(first(dylib_id_lcs))
            end
        end

        # Locate the build products within the prefix, ensure that all the dylib ID's
        # now match the pattern `@rpath/$(basename(p))`
        no_id_path = locate(no_id, prefix; platform=platform)
        abs_id_path = locate(abs_id, prefix; platform=platform)
        right_id_path = locate(right_id, prefix; platform=platform)
        for p in (no_id_path, abs_id_path, right_id_path)
            @test any(startswith.(p, libdirs(prefix)))
            @test get_dylib_id(p) == "@rpath/$(basename(p))"
        end

        # Only if it already has an `@rpath/`-ified ID, it doesn't get touched.
        wrong_id_path = locate(wrong_id, prefix; platform=platform)
        @test any(startswith.(wrong_id_path, libdirs(prefix)))
        @test get_dylib_id(wrong_id_path) == "@rpath/totally_different.dylib"
    end
end

@testset "Auditor - absolute paths" begin
    mktempdir() do build_path
        sharedir = joinpath(realpath(build_path), "share")
        mkpath(sharedir)
        open(joinpath(sharedir, "foo.conf"), "w") do f
            write(f, "share_dir = \"$sharedir\"")
        end

        # Test that `audit()` warns about an absolute path within the prefix
        @test_logs (:warn, r"share/foo.conf contains an absolute path") match_mode=:any begin
            Auditor.audit(Prefix(build_path); verbose=true)
        end
    end
end

@testset "Auditor - broken symlinks" begin
    mktempdir() do build_path
        bindir = joinpath(realpath(build_path), "bin")
        mkpath(bindir)
        # Test both broken and working (but external) symlinks
        symlink("../../artifacts/1a2b3/lib/libzmq.dll.a", joinpath(bindir, "libzmq.dll.a"))
        # The following symlinks shouldn't raise a warning
        symlink("/bin/bash", joinpath(bindir, "bash.exe"))
        symlink("libfoo.so.1.2.3", joinpath(bindir, "libfoo.so"))

        # Test that `audit()` warns about broken symlinks
        @test_logs (:warn, r"Broken symlink: bin/libzmq.dll.a") match_mode=:any begin
            Auditor.warn_deadlinks(build_path)
        end
    end
end

@testset "Auditor - gcc version" begin
    # These tests assume our gcc version is concrete (e.g. that Julia is linked against libgfortran)
    our_libgfortran_version = libgfortran_version(platform)
    @test our_libgfortran_version != nothing

    mktempdir() do build_path
        hello_world = ExecutableProduct("hello_world_fortran", :hello_world_fortran)
        build_output_meta = @test_logs (:warn, r"CompilerSupportLibraries_jll") match_mode=:any begin
            autobuild(
                build_path,
                "hello_fortran",
                v"1.0.0",
                # No sources
                FileSource[],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                    # Build fortran hello world
                    make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                    # Install fake license just to silence the warning
                    install_license /usr/share/licenses/libuv/LICENSE
                    """,
                # Build for our platform
                [platform],
                #
                Product[hello_world],
                # No dependencies
                Dependency[];
            )
        end

        # Extract our platform's build, run the hello_world tests:
        output_meta = select_platform(build_output_meta, platform)
        @test output_meta != nothing
        tarball_path, tarball_hash = output_meta[1:2]

        # Ensure the build products were created
        @test isfile(tarball_path)

        # Unpack it somewhere else
        @test verify(tarball_path, tarball_hash)
        testdir = joinpath(build_path, "testdir")
        mkdir(testdir)
        unpack(tarball_path, testdir)

        # Attempt to run the executable, we expect it to work since it's our platform:
        hello_world_path = locate(hello_world, Prefix(testdir); platform=platform)
        with_libgfortran() do
            @test strip(String(read(`$hello_world_path`))) == "Hello, World!"
        end

        # If we audit the testdir, pretending that we're trying to build an ABI-agnostic
        # tarball, make sure it warns us about it.
        @test_logs (:warn, r"links to libgfortran!") match_mode=:any begin
            Auditor.audit(Prefix(testdir); platform=BinaryBuilderBase.abi_agnostic(platform), autofix=false)
        end
    end
end

@testset "Auditor - soname matching" begin
    mktempdir() do build_path
        build_output_meta = nothing
        linux_platform = Platform("x86_64", "linux")
        @test_logs (:info, r"creating link to libfoo\.so\.1\.0\.0") match_mode=:any begin
            build_output_meta = autobuild(
                build_path,
                "soname_matching",
                v"1.0.0",
                # No sources
                FileSource[],
                # Build the library only with the versioned name
                raw"""
                mkdir -p ${prefix}/lib
                cc -o ${prefix}/lib/libfoo.${dlext}.1.0.0 -fPIC -shared /usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
                # Set the soname to a non-existing file
                patchelf --set-soname libfoo.so ${prefix}/lib/libfoo.${dlext}.1.0.0
                """,
                # Build for Linux
                [linux_platform],
                # Ensure our executable products are built
                [LibraryProduct("libfoo", :libfoo)],
                # No dependencies
                Dependency[];
                autofix = true,
                verbose = true,
                require_license = false
            )
        end
        # Extract our platform's build
        @test haskey(build_output_meta, linux_platform)
        tarball_path, tarball_hash = build_output_meta[linux_platform][1:2]
        # Ensure the build products were created
        @test isfile(tarball_path)

        # Unpack it somewhere else
        @test verify(tarball_path, tarball_hash)
        testdir = joinpath(build_path, "testdir")
        mkdir(testdir)
        unpack(tarball_path, testdir)
        @test readlink(joinpath(testdir, "lib", "libfoo.so")) == "libfoo.so.1.0.0"
    end
end
