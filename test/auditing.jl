# Tests for our auditing infrastructure

@testset "Auditor - cppfilt" begin
    # We take some known x86_64-linux-gnu symbols and pass them through c++filt
    mangled_symbol_names = [
        "_ZNKSt7__cxx1110_List_baseIiSaIiEE13_M_node_countEv",
        "_ZNKSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE6lengthEv@@GLIBCXX_3.4.21",
        "_Z10my_listlenNSt7__cxx114listIiSaIiEEE",
        "_ZNKSt7__cxx114listIiSaIiEE4sizeEv",
    ]
    unmangled_symbol_names = BinaryBuilder.cppfilt(mangled_symbol_names, Linux(:x86_64))
    @test all(unmangled_symbol_names .== [
        "std::__cxx11::_List_base<int, std::allocator<int> >::_M_node_count() const",
        "std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::length() const@@GLIBCXX_3.4.21",
        "my_listlen(std::__cxx11::list<int, std::allocator<int> >)",
        "std::__cxx11::list<int, std::allocator<int> >::size() const",
    ])
end

@testset "Auditor - ISA tests" begin
    mktempdir() do build_path
        products = Product[
            ExecutableProduct("main_sse", :main_sse),
            ExecutableProduct("main_avx", :main_avx),
            ExecutableProduct("main_avx2", :main_avx2),
        ]

        build_output_meta = nothing
        @test_logs (:warn, r"sandybridge") (:warn, r"haswell") match_mode=:any begin
            build_output_meta = autobuild(
                build_path,
                "isa_tests",
                v"1.0.0",
                [build_tests_dir],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                cd ${WORKSPACE}/srcdir/isa_tests
                make -j${nproc} install
                install_license /usr/include/ltdl.h
                """,
                # Build for our platform
                [platform],
                # Ensure our executable products are built
                products,
                # No dependencies
                [];
                # We need to build with very recent GCC so that we can emit AVX2
                preferred_gcc_version=v"8",
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

        # Run ISA tests
        for (product, true_isa) in zip(products, (:core2, :sandybridge, :haswell))
            readmeta(locate(product, prefix)) do oh
                detected_isa = BinaryBuilder.analyze_instruction_set(oh, platform; verbose=true)
                @test detected_isa == true_isa
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
            [build_tests_dir],
            script,
            # Build for this platform
            [platform],
            # The products we expect to be build
            [libcxxstringabi_test],
            # No depenedencies
            [];
            preferred_gcc_version=gcc_version
        )
    end

    for platform in (Linux(:x86_64; compiler_abi=CompilerABI(;cxxstring_abi=:cxx03)),
                     Linux(:x86_64; compiler_abi=CompilerABI(;cxxstring_abi=:cxx11)))
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
                    detected_cxxstring_abi = BinaryBuilder.detect_cxxstring_abi(oh, platform)
                    @test detected_cxxstring_abi == cxxstring_abi(platform)
                end

                # Explicitly test cxx string abi mismatches
                if gcc_version > v"4"
                    script = """
                        mkdir -p \${libdir}
                        /opt/\${target}/bin/\${target}-g++ -fPIC \\
                            -D_GLIBCXX_USE_CXX11_ABI=$(cxxstring_abi(platform) == :cxx03 ? "1" : "0") \\
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
    platform = Linux(:x86_64)
    mktempdir() do build_path
        @test_logs (:warn, r"contains std::string values") match_mode=:any begin
            do_build(build_path, script, platform, v"6")
        end
    end
end


@testset "Auditor - .dll moving" begin
    for platform in [Windows(:x86_64)]
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:warn, r"lib/libfoo.dll should be in `bin`") (:warn, r"Simple buildsystem detected") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "dll_moving",
                    v"1.0.0",
                    [],
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
                    []
                )
            end

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Test that `libfoo.dll` gets moved to `bin` if it's a windows
            contents = list_tarball_files(tarball_path)
            @test "bin/libfoo.$(dlext(platform))" in contents
        end
    end
end

@testset "Auditor - .dylib identity mismatch" begin
    mktempdir() do build_path
        no_id = LibraryProduct("no_id", :no_id)
        abs_id = LibraryProduct("abs_id", :wrong_id)
        wrong_id = LibraryProduct("wrong_id", :wrong_id)
        right_id = LibraryProduct("right_id", :wrong_id)
        platform = MacOS()

        build_output_meta = autobuild(
            build_path,
            "dll_moving",
            v"1.0.0",
            [],
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
            [],
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
            BinaryBuilder.audit(Prefix(build_path); verbose=true)
        end
    end
end

@testset "Auditor - gcc version" begin
    # These tests assume our gcc version is concrete (e.g. that Julia is linked against libgfortran)
    our_libgfortran_version = libgfortran_version(compiler_abi(platform))
    @test our_libgfortran_version != nothing

    # Get one that isn't us.
    other_libgfortran_version = v"4"
    if our_libgfortran_version == other_libgfortran_version
        other_libgfortran_version = v"5"
    end

    our_platform = platform
    other_platform = BinaryBuilder.replace_libgfortran_version(our_platform, other_libgfortran_version)
    
    for platform in (our_platform, other_platform)
        # Build `hello_world` in fortran for all three platforms; on our platform we expect it
        # to run, on `other` platform we expect it to not run, on `fail` platform we expect it
        # to throw an error during auditing:
        mktempdir() do build_path
            hello_world = ExecutableProduct("hello_world_fortran", :hello_world_fortran)
            build_output_meta = autobuild(
                build_path,
                "hello_fortran",
                v"1.0.0",
                # No sources
                [],
                # Build the test suite, install the binaries into our prefix's `bin`
                raw"""
                # Build fortran hello world
                make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                # Install fake license just to silence the warning
                install_license /usr/share/licenses/libuv/LICENSE
                """,
                # Build for ALL the platforms
                [platform],
                # 
                Product[hello_world],
                # No dependencies
                [];
            )

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

            # Attempt to run the executable, but only expect it to work if it's our platform:
            hello_world_path = locate(hello_world, Prefix(testdir); platform=platform)
            with_libgfortran() do
                if platform == our_platform
                    @test strip(String(read(`$hello_world_path`))) == "Hello, World!"
                elseif platform == other_platform
                    fail_cmd = pipeline(`$hello_world_path`, stdout=devnull, stderr=devnull)
                    @test_throws ProcessFailedException run(fail_cmd)
                end
            end

            # If we audit the testdir, pretending that we're trying to build an ABI-agnostic
            # tarball, make sure it warns us about it.
            @test_logs (:warn, r"links to libgfortran!") match_mode=:any begin
                BinaryBuilder.audit(Prefix(testdir); platform=BinaryBuilder.abi_agnostic(platform), autofix=false)
            end
        end
    end
end
