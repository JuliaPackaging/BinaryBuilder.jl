using BinaryBuilder.Auditor
using BinaryBuilder.Auditor: check_os_abi, compatible_marchs, is_for_platform, valid_library_path
using ObjectFile

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

    # Do the same, for macOS, whose compilers usually prepend an additional underscore to symbols
    mangled_symbol_names = [
        "__ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEC1EPKcRKS3_.isra.41",
        "__ZStplIcSt11char_traitsIcESaIcEENSt7__cxx1112basic_stringIT_T0_T1_EEOS8_PKS5_",
        "__ZNSt6vectorISt4pairINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt3mapIS6_S6_St4lessIS6_ESaIS0_IKS6_S6_EEEESaISE_EED1Ev",
        "__ZNSt8_Rb_treeINSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEEESt4pairIKS5_S5_ESt10_Select1stIS8_ESt4lessIS5_ESaIS8_EE7_M_copyINSE_11_Alloc_nodeEEEPSt13_Rb_tree_nodeIS8_EPKSI_PSt18_Rb_tree_node_baseRT_",
    ]
    unmangled_symbol_names = Auditor.cppfilt(mangled_symbol_names, Platform("x86_64", "macos"); strip_underscore=true)
    # binutils and llvm c++filt slightly disagree on the formatting of final annotation of
    # this symbol (`[clone .isra.41]` for the former, `(.isra.41)` for the latter), so we
    # only compare the rest.
    @test startswith(unmangled_symbol_names[1],
                     "std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >::basic_string(char const*, std::allocator<char> const&)")
    @test all(unmangled_symbol_names[2:end] .== [
        "std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > std::operator+<char, std::char_traits<char>, std::allocator<char> >(std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >&&, char const*)",
        "std::vector<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::map<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::map<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > > > > >::~vector()",
        "std::_Rb_tree_node<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > >* std::_Rb_tree<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::_Select1st<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > >::_M_copy<std::_Rb_tree<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::_Select1st<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > >::_Alloc_node>(std::_Rb_tree_node<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > const*, std::_Rb_tree_node_base*, std::_Rb_tree<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> >, std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::_Select1st<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > >, std::less<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > >, std::allocator<std::pair<std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > const, std::__cxx11::basic_string<char, std::char_traits<char>, std::allocator<char> > > > >::_Alloc_node&)",
    ])
end

@testset "Auditor - ISA tests" begin
    @test compatible_marchs(Platform("x86_64", "linux")) == ["x86_64"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="x86_64")) == ["x86_64"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx")) == ["x86_64", "avx"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx2")) == ["x86_64", "avx", "avx2"]
    @test compatible_marchs(Platform("x86_64", "linux"; march="avx512")) == ["x86_64", "avx", "avx2", "avx512"]
    @test compatible_marchs(Platform("armv7l", "linux")) == ["armv7l"]
    @test compatible_marchs(Platform("i686", "linux"; march="prescott")) == ["pentium4", "prescott"]
    @test compatible_marchs(Platform("aarch64", "linux"; march="armv8_1")) == ["armv8_0", "armv8_1"]

    product = ExecutableProduct("main", :main)

    # The microarchitecture of the product doesn't match the target architecture: complain!
    mktempdir() do build_path
        platform = Platform("x86_64", "linux"; march="avx")
        build_output_meta = nothing
        @test_logs (:info, "Building for x86_64-linux-gnu-march+avx") (:warn, r"is avx512, not avx as desired\.$") match_mode=:any begin
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
            readmeta(locate(product, prefix)) do ohs
                foreach(ohs) do oh
                    detected_isa = Auditor.analyze_instruction_set(oh, platform; verbose=true)
                    @test detected_isa == "avx512"
                end
            end
        end
    end

    # The instruction set of the product is compatible with the target
    # architecture, but it's lower than desired: issue a gentle warning
    mktempdir() do build_path
        platform = Platform("x86_64", "linux"; march="avx512")
        build_output_meta = nothing
        @test_logs (:info, "Building for x86_64-linux-gnu-march+avx512") (:warn, r"is avx, not avx512 as desired\. You may be missing some optimization flags during compilation\.$") match_mode=:any begin
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
            readmeta(locate(product, prefix)) do ohs
                foreach(ohs) do oh
                    detected_march = Auditor.analyze_instruction_set(oh, platform; verbose=true)
                    @test detected_march == "avx"
                end
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
            readmeta(locate(product, prefix)) do ohs
                foreach(ohs) do oh
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
            # No dependencies
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
                build_output_meta = @test_logs (:info, "Building for $(triplet(platform))") (:warn, r"Linked library libgcc_s\.so\.1") match_mode=:any do_build(build_path, script, platform, gcc_version)
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
                readmeta(locate(libcxxstringabi_test, prefix)) do ohs
                    foreach(ohs) do oh
                        detected_cxxstring_abi = Auditor.detect_cxxstring_abi(oh, platform)
                        @test detected_cxxstring_abi == cxxstring_abi(platform)
                    end
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


@testset "Auditor - .la removal" begin
    for os in ["linux", "macos", "freebsd", "windows"]
        platform = Platform("x86_64", os)
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:info, r"Removing libtool file .*/destdir/lib/libfoo\.la$") (:info, r"Removing libtool file .*/destdir/lib/libqux\.la$") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "libfoo",
                    v"1.0.0",
                    # Copy in the libfoo sources
                    [DirectorySource(build_tests_dir)],
                    # Build libfoo using autotools to create a real .la file, and also
                    # create a fake .la file (which should not be removed).  Create also a
                    # symlink libqux.la -> libfoo.la, which will be broken after libfoo.la
                    # has been deleted: remove libqux.la as well
                    libfoo_autotools_script * raw"""
                    touch ${prefix}/lib/libbar.la
                    ln -s ${prefix}/lib/libfoo.la ${prefix}/lib/libqux.la
                    """,
                    # Build for our platform
                    [platform],
                    # The products we expect to be build
                    libfoo_products,
                    # No dependencies
                    Dependency[];
                    verbose = true,
                )
            end

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Test that `libfoo.la` and `libqux.la` have been removed but `libbar.la` hasn't
            contents = list_tarball_files(tarball_path)
            @test "lib/libbar.la" in contents
            @test !("lib/libfoo.la" in contents)
            @test !("lib/libqux.la" in contents)
        end
    end
end

@testset "Auditor - relocatable pkg-config prefix" begin
    for os in ["linux", "macos", "freebsd", "windows"]
        platform = Platform("x86_64", os)
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:info, r"Relocatize pkg-config file .*/destdir/lib/pkgconfig/libfoo\.pc$") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "libfoo",
                    v"1.0.0",
                    # Copy in the libfoo sources
                    [DirectorySource(build_tests_dir)],
                    libfoo_autotools_script,
                    # Build for our platform
                    [platform],
                    # The products we expect to be build
                    libfoo_products,
                    # No dependencies
                    Dependency[];
                    verbose = true,
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

            # Test that `libfoo.pc` exists and contains a relative prefix
            # TODO: actually use pkg-config with PKG_CONFIG_PATH
            contents = list_tarball_files(tarball_path)
            @test "lib/pkgconfig/libfoo.pc" in contents
            libfoo_pc = read(joinpath(testdir, "lib/pkgconfig/libfoo.pc"), String)
            @test contains(libfoo_pc, "prefix=\${pcfiledir}")
            @test !contains(libfoo_pc, "/workplace/destdir")
        end
    end
end

@testset "Auditor - .dll moving" begin
    for platform in [Platform("x86_64", "windows")]
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:warn, r"lib/libfoo\.dll should be in `bin`") (:warn, r"Simple buildsystem detected") match_mode=:any begin
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
                    # Ensure our library product is built
                    [LibraryProduct("libfoo", :libfoo)],
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
            mkdir -p "${libdir}"
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
        function get_dylib_ids(path)
            return readmeta(path) do ohs
                map(ohs) do oh
                     dylib_id_lcs = [lc for lc in MachOLoadCmds(oh) if isa(lc, MachOIdDylibCmd)]
                     @test !isempty(dylib_id_lcs)
                     return dylib_name(first(dylib_id_lcs))
                end
            end
        end

        # Locate the build products within the prefix, ensure that all the dylib ID's
        # now match the pattern `@rpath/$(basename(p))`
        no_id_path = locate(no_id, prefix; platform=platform)
        abs_id_path = locate(abs_id, prefix; platform=platform)
        right_id_path = locate(right_id, prefix; platform=platform)
        for p in (no_id_path, abs_id_path, right_id_path)
            @test any(startswith.(p, libdirs(prefix)))
            @test all(get_dylib_ids(p) .== "@rpath/$(basename(p))")
        end

        # Only if it already has an `@rpath/`-ified ID, it doesn't get touched.
        wrong_id_path = locate(wrong_id, prefix; platform=platform)
        @test any(startswith.(wrong_id_path, libdirs(prefix)))
        @test all(get_dylib_ids(wrong_id_path) .== "@rpath/totally_different.dylib")

        # Ensure that this bianry is codesigned
        @test BinaryBuilder.Auditor.check_codesigned(right_id_path, platform)
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
        @test_logs (:warn, r"share/foo\.conf contains an absolute path") match_mode=:any begin
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
        @test_logs (:warn, r"Broken symlink: bin/libzmq\.dll\.a") match_mode=:any begin
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
        build_output_meta = @test_logs (:warn, r"CompilerSupportLibraries_jll") (:warn, r"Linked library libgfortran\.so\.(4|5)") (:warn, r"Linked library libquadmath\.so\.0") (:warn, r"Linked library libgcc_s\.so\.1") match_mode=:any begin
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
                # Note: we purposefully don't require CompilerSupportLibraries, even if we
                # should, but the `@test_logs` above makes sure the audit warns us about
                # this problem.
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
            @test readchomp(`$hello_world_path`) == "Hello, World!"
        end

        # If we audit the testdir, pretending that we're trying to build an ABI-agnostic
        # tarball, make sure it warns us about it.
        @test_logs (:warn, r"links to libgfortran!") match_mode=:any begin
            @test !Auditor.audit(Prefix(testdir); platform=BinaryBuilderBase.abi_agnostic(platform), autofix=false)
            # Make sure audit is otherwise happy with the executable
            # Note by Mosè: this test was introduced before
            # https://github.com/JuliaPackaging/BinaryBuilder.jl/pull/1240 and relied on the
            # fact audit was ok with not depending on CSL for packages needing GCC
            # libraries, but that was a fallacious expectation.  At the moment I don't know
            # how to meaningfully use this test, leaving here as broken until we come up
            # with better ideas (just remove the test?).
            @test Auditor.audit(Prefix(testdir); platform=platform, autofix=false) broken=true
        end

        # Let's pretend that we're building for a different libgfortran version:
        # audit should warn us.
        libgfortran_versions = (3, 4, 5)
        other_libgfortran_version = libgfortran_versions[findfirst(v -> v != our_libgfortran_version.major, libgfortran_versions)]
        @test_logs (:warn, Regex("but we are supposedly building for libgfortran$(other_libgfortran_version)")) (:warn, r"Linked library libgfortran\.so\.(4|5)") (:warn, r"Linked library libquadmath\.so\.0") (:warn, r"Linked library libgcc_s\.so\.1") readmeta(hello_world_path) do ohs
            foreach(ohs) do oh
                p = deepcopy(platform)
                p["libgfortran_version"] = "$(other_libgfortran_version).0.0"
                @test !Auditor.audit(Prefix(testdir); platform=p, autofix=false)
            end
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
                mkdir -p "${libdir}"
                cc -o "${libdir}/libfoo.${dlext}.1.0.0" -fPIC -shared /usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
                # Set the soname to a non-existing file
                patchelf --set-soname libfoo.so "${libdir}/libfoo.${dlext}.1.0.0"
                """,
                # Build for Linux
                [linux_platform],
                # Ensure our library product is built
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

@testset "Auditor - rpaths" begin
    @testset "$platform" for platform in (Platform("x86_64", "linux"; libc="glibc"), Platform("x86_64", "macos"))
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:info, "Building for $(triplet(platform))") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "rpaths",
                    v"1.0.0",
                    # No sources
                    FileSource[],
                    # Build two libraries, `libbar` in `${libdir}/qux/` and `libfoo` in
                    # `${libdir}`, with the latter linking to the former.
                    raw"""
                    mkdir -p ${libdir}/qux
                    echo "int bar(){return 38;}" | gcc -x c -shared -fPIC - -o ${libdir}/qux/libbar.${dlext}
                    echo "extern int bar(); int foo(){return bar() + 4;}" | gcc -x c -shared -fPIC - -o ${libdir}/libfoo.${dlext} -L${libdir}/qux -lbar -Wl,-rpath,${libdir}/qux
                    """,
                    [platform],
                    # Ensure our library products are built
                    [LibraryProduct("libbar", :libbar, "\$libdir/qux"), LibraryProduct("libfoo", :libfoo)],
                    # No dependencies
                    Dependency[];
                    require_license = false
                )
            end
            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            # Ensure the build products were created
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            # Make sure rpath of libbar is empty
            @test Auditor._rpaths(joinpath(testdir, "lib", "qux", "libbar.$(platform_dlext(platform))")) == []
            # Make sure the rpath of libfoo contains only `$ORIGIN/qux`, with the relative
            # path handled correctly.
            libfoo_rpaths = Auditor._rpaths(joinpath(testdir, "lib", "libfoo.$(platform_dlext(platform))"))
            @test (Sys.isapple(platform) ? "@loader_path" : "\$ORIGIN") * "/qux" in libfoo_rpaths
            # Currently we don't filter out absolute rpaths for macOS libraries, no good.
            @test length(libfoo_rpaths) == 1 broken=Sys.isapple(platform)
        end
    end

    @testset "GCC libraries" begin
        platform = Platform("x86_64", "linux"; libc="glibc", libgfortran_version=v"5")
        mktempdir() do build_path
            build_output_meta = nothing
            @test_logs (:info, "Building for $(triplet(platform))") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "rpaths",
                    v"2.0.0",
                    # No sources
                    FileSource[],
                    # Build two libraries, `libbar` in `${libdir}/qux/` and `libfoo` in
                    # `${libdir}`, with the latter linking to the former.
                    raw"""
                    # Build fortran hello world
                    make -j${nproc} -sC /usr/share/testsuite/fortran/hello_world install
                    # Install fake license just to silence the warning
                    install_license /usr/share/licenses/libuv/LICENSE
                    """,
                    [platform],
                    # Ensure our library products are built
                    [ExecutableProduct("hello_world_fortran", :hello_world_fortran)],
                    # Dependencies: add CSL
                    [Dependency("CompilerSupportLibraries_jll")];
                    autofix=true,
                )
            end
            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            # Ensure the build products were created
            @test isfile(tarball_path)
            # Ensure reproducibility of build
            @test build_output_meta[platform][3] == Base.SHA1("8805236c0abcca3b393e184f67bb89291b3f2d28")

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            # Make sure auditor set the rpath of `hello_world`, even if it links only to
            # libgfortran.
            @test Auditor._rpaths(joinpath(testdir, "bin", "hello_world_fortran")) == ["\$ORIGIN/../lib"]
        end
    end
end

@testset "Auditor - execution permission" begin
    mktempdir() do build_path
        build_output_meta = nothing
        product = LibraryProduct("libfoo", :libfoo)
        @test_logs (:info, r"Making .*libfoo.* executable") match_mode=:any begin
            build_output_meta = autobuild(
                build_path,
                "exec",
                v"1.0.0",
                # No sources
                FileSource[],
                # Build a library without execution permissions
                raw"""
                mkdir -p "${libdir}"
                cc -o "${libdir}/libfoo.${dlext}" -fPIC -shared /usr/share/testsuite/c/dyn_link/libfoo/libfoo.c
                chmod 640 "${libdir}/libfoo.${dlext}"
                """,
                # Build for our platform
                [platform],
                # Ensure our library product is built
                [product],
                # No dependencies
                Dependency[];
                verbose = true,
                require_license = false
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
        libfoo_path = joinpath(testdir, build_output_meta[platform][4][product]["path"])
        # Tar.jl normalizes permissions of executable files to 0o755, instead of
        # recording exact original permissions:
        # https://github.com/JuliaIO/Tar.jl/blob/37766a22f5a6ac9f07022d83debd5db7d7a4b896/README.md#permissions
        @test_broken filemode(libfoo_path) & 0o777 == 0o750
    end
end

# References:
# * https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/1232
# * https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/1245
@testset "Auditor - Reproducible libraries on Windows" begin
    platform = Platform("i686", "windows")
    expected_git_shas = Dict(
        v"4" => Base.SHA1("1b625af3aa29c4b4b398f1eeaccc83d781bca1a5"),
        v"6" => Base.SHA1("a65f72e29a87cc8a5f048069abf6a250527563c9"),
    )
    @testset "gcc version $(gcc_version)" for gcc_version in (v"4", v"6")
        mktempdir() do build_path
            build_output_meta = nothing
            product = LibraryProduct("libfoo", :libfoo)
            @test_logs (:info, r"Normalising timestamps in import library") match_mode=:any begin
                build_output_meta = autobuild(
                    build_path,
                    "implib",
                    v"1.0.0",
                    # No sources
                    FileSource[],
                    # Build a library without execution permissions
                    raw"""
                    mkdir -p "${libdir}"
                    cd "${libdir}"
                    echo 'int foo(){ return 42; }' | cc -x c -shared - -o libfoo.${dlext} -Wl,--out-implib,libfoo.${dlext}.a
                    """,
                    # Build for Windows
                    [platform],
                    # Ensure our library product is built
                    [product],
                    # No dependencies
                    Dependency[];
                    verbose = true,
                    require_license = false,
                    preferred_gcc_version = gcc_version,
                )
            end

            # Extract our platform's build
            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)
            # Ensure reproducibility of build
            # TODO: fix reproducibility with GCC v5+:
            # https://github.com/JuliaPackaging/BinaryBuilderBase.jl/pull/435#issuecomment-3185007378
            @test build_output_meta[platform][3] == expected_git_shas[gcc_version] skip=gcc_version>=v"5"
        end
    end
end

@testset "Auditor - other checks" begin
    @testset "hard-float ABI" begin
        platform = Platform("armv7l", "linux"; call_abi = "eabihf", libc = "glibc")
        mktempdir() do build_path
            build_output_meta = @test_logs (:error, r"libsoft\.so does not match the hard-float ABI") match_mode=:any begin
                autobuild(
                    build_path,
                    "hard_float_ABI",
                    v"1.0.0",
                    # No sources
                    FileSource[],
                    # Build a library which doesn't link to the standard library and
                    # forces the soft-float ABI
                    raw"""
                    mkdir -p "${libdir}" "${bindir}"
                    # This library has hard-float ABI
                    echo 'int test() { return 0; }' | cc -shared -fPIC -o "${libdir}/libhard.${dlext}" -x c -
                    # This library has soft-float ABI
                    echo 'int _start() { return 0; }' | /opt/${target}/bin/${target}-gcc -nostdlib -shared -mfloat-abi=soft -o "${libdir}/libsoft.${dlext}" -x c -
                    # hello_world built by Go doesn't specify any float ABI
                    make -C /usr/share/testsuite/go/hello_world/
                    cp "/tmp/testsuite/${target}/go/hello_world/hello_world" "${bindir}/hello_world"
                    """,
                    # Build for Linux armv7l hard-float
                    [platform],
                    # Ensure our library product is built
                    [
                        LibraryProduct("libhard", :libhard),
                        LibraryProduct("libsoft", :libsoft),
                        ExecutableProduct("hello_world", :hello_world),
                    ],
                    # No dependencies
                    Dependency[];
                    compilers = [:c, :go],
                    verbose = true,
                    require_license = false
                )
            end

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            # Remove libsoft.so, we want to run audit only on the other products
            rm(joinpath(testdir, "lib", "libsoft.so"))
            # Make sure `hello_world` passes the float ABI check even if it doesn't
            # set `EF_ARM_ABI_FLOAT_HARD`.
            @test Auditor.audit(Prefix(testdir); platform=platform, require_license=false)
        end
    end
    @testset "OS/ABI: $platform" for platform in [Platform("x86_64", "freebsd"),
                                                  Platform("aarch64", "freebsd")]
        mktempdir() do build_path
            build_output_meta = @test_logs (:warn, r"Skipping binary analysis of lib/lib(nonote|badosabi)\.so \(incorrect platform\)") match_mode=:any begin
                autobuild(
                    build_path,
                    "OSABI",
                    v"4.2.0",
                    # No sources
                    FileSource[],
                    # Build a library with a mismatched OS/ABI in the ELF header
                    raw"""
                    apk update
                    apk add binutils
                    mkdir -p "${libdir}"
                    cd "${libdir}"
                    echo 'int wrong() { return 0; }' | cc -shared -fPIC -o "libwrong.${dlext}" -x c -
                    echo 'int right() { return 0; }' | cc -shared -fPIC -o "libright.${dlext}" -x c -
                    cp "libwrong.${dlext}" "libnonote.${dlext}"
                    # We only check for a branded ELF note when the OS/ABI is 0
                    elfedit --output-osabi=none "libnonote.${dlext}"
                    strip --remove-section=.note.tag "libnonote.${dlext}"
                    mv "libwrong.${dlext}" "libbadosabi.${dlext}"
                    # NetBSD runs anywhere, which implies that anything that runs is for NetBSD, right?
                    elfedit --output-osabi=NetBSD "libbadosabi.${dlext}"
                    """,
                    [platform],
                    # Ensure our library product is built
                    [
                        LibraryProduct("libbadosabi", :libbadosabi),
                        LibraryProduct("libnonote", :libnonote),
                        LibraryProduct("libright", :libright),
                    ],
                    # No dependencies
                    Dependency[];
                    verbose=true,
                    require_license=false,
                )
            end

            @test haskey(build_output_meta, platform)
            tarball_path, tarball_hash = build_output_meta[platform][1:2]
            @test isfile(tarball_path)

            # Unpack it somewhere else
            @test verify(tarball_path, tarball_hash)
            testdir = joinpath(build_path, "testdir")
            mkdir(testdir)
            unpack(tarball_path, testdir)
            readmeta(joinpath(testdir, "lib", "libright.so")) do ohs
                oh = only(ohs)
                @test is_for_platform(oh, platform)
                @test check_os_abi(oh, platform)
            end
            readmeta(joinpath(testdir, "lib", "libnonote.so")) do ohs
                oh = only(ohs)
                @test !is_for_platform(oh, platform)
                @test !check_os_abi(oh, platform)
                @test_logs((:warn, r"libnonote\.so does not have a FreeBSD-branded ELF note"),
                           match_mode=:any, check_os_abi(oh, platform; verbose=true))
            end
            readmeta(joinpath(testdir, "lib", "libbadosabi.so")) do ohs
                oh = only(ohs)
                @test !is_for_platform(oh, platform)
                @test !check_os_abi(oh, platform)
                @test_logs((:warn, r"libbadosabi\.so has an ELF header OS/ABI value that is not set to FreeBSD"),
                           match_mode=:any, check_os_abi(oh, platform; verbose=true))
            end
            # Only audit the library we didn't mess with in the recipe
            for bad in ("nonote", "badosabi")
                rm(joinpath(testdir, "lib", "lib$bad.so"))
            end
            @test Auditor.audit(Prefix(testdir); platform=platform, require_license=false)
        end
    end
end

@testset "valid_library_path" begin
    linux = Platform("x86_64", "linux")
    macos = Platform("x86_64", "macos")
    windows = Platform("x86_64", "windows")

    @test valid_library_path("/usr/libc.dylib", macos)
    @test !valid_library_path("/usr/libc.dylib.", macos)
    @test !valid_library_path("/usr/libc.dylib.1", macos)
    @test !valid_library_path("/usr/libc.dylib", linux)
    @test !valid_library_path("/usr/libc.dylib", windows)

    @test valid_library_path("libc.dll", windows)
    @test !valid_library_path("libc.dll.1", windows)
    @test !valid_library_path("libc.dll", linux)
    @test !valid_library_path("libc.dll", macos)

    @test valid_library_path("/usr/libc.so", linux)
    @test valid_library_path("/usr/libc.so.1", linux)
    @test valid_library_path("/usr/libc.so.1.2", linux)
    @test !valid_library_path("/usr/libc.so.", linux)
    @test !valid_library_path("/usr/libc.sot", linux)
    @test !valid_library_path("/usr/libc.so", macos)
    @test !valid_library_path("/usr/libc.so", windows)
end
