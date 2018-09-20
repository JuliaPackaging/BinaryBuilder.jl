# Tests for our auditing infrastructure

# @testset "Auditor - ISA tests" begin
#     begin
#         build_path = tempname()
#         mkpath(build_path)
#         isa_platform = Linux(:x86_64; compiler_abi=CompilerABI(:gcc8, :cxx_any))
#         prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], isa_platform)

#         main_sse = ExecutableProduct(prefix, "main_sse", :main_sse)
#         main_avx = ExecutableProduct(prefix, "main_avx", :main_avx)
#         main_avx2 = ExecutableProduct(prefix, "main_avx2", :main_avx2)
#         products = [main_sse, main_avx, main_avx2]

#         cd(joinpath(dirname(@__FILE__),"build_tests","isa_tests")) do
#             run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

#             # Build isa tests
#             script="""
#             /usr/bin/make clean
#             /usr/bin/make install
#             """

#             # Build it
#             @test build(ur, "isa_tests", products, script, isa_platform, prefix; verbose=true)

#             # Ensure it's satisfied
#             @test all(satisfied(r; verbose=true) for r in products)
#         end

#         # Next, test isa of these files
#         readmeta(locate(main_sse)) do oh
#             isa_sse = BinaryBuilder.analyze_instruction_set(oh, isa_platform; verbose=true)
#             @test isa_sse == :core2
#         end

#         readmeta(locate(main_avx)) do oh
#             isa_avx = BinaryBuilder.analyze_instruction_set(oh, isa_platform; verbose=true)
#             @test isa_avx == :sandybridge
#         end

#         readmeta(locate(main_avx2)) do oh
#             isa_avx2 = BinaryBuilder.analyze_instruction_set(oh, isa_platform; verbose=true)
#             @test isa_avx2 == :haswell
#         end

#         # Delete the build path
#         rm(build_path, recursive = true)
#     end
# end

# @testset "Auditor - .dll moving" begin
#     begin
#         build_path = tempname()
#         mkpath(build_path)
#         dll_platform = Windows(:x86_64)
#         prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], dll_platform)
#         cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
#             run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

#             # First, build libfoo, but with a dumb script that doesn't know to put .dll files in bin
#             dumb_script = """
#             /usr/bin/make clean
#             /usr/bin/make install libdir=\$prefix/lib
#             """

#             @test build(ur, "foo", libfoo_products(prefix), libfoo_script, dll_platform, prefix; autofix=false)
#         end

#         # Test that libfoo puts its .dll's into lib, even on windows:
#         @test !isfile(joinpath(prefix, "bin", "libfoo.dll"))
#         @test isfile(joinpath(prefix, "lib", "libfoo.dll"))

#         # Test that `audit()` moves it to `bin`.
#         BinaryBuilder.audit(prefix; platform=dll_platform, verbose=true, autofix=true)
#         @test isfile(joinpath(prefix, "bin", "libfoo.dll"))
#         @test !isfile(joinpath(prefix, "lib", "libfoo.dll"))
#     end
# end

# @testset "Auditor - absolute paths" begin
#     prefix = Prefix(tempname())
#     try
#         sharedir = joinpath(prefix.path, "share")
#         mkpath(sharedir)
#         open(joinpath(sharedir, "foo.conf"), "w") do f
#             write(f, "share_dir = \"$sharedir\"")
#         end

#         # Test that `audit()` warns about an absolute path within the prefix
#         @test_warn "share/foo.conf" BinaryBuilder.audit(prefix)
#     finally
#         rm(prefix.path; recursive=true)
#     end
# end

@testset "Auditor - gcc version" begin
    begin
        build_path = tempname()

        # These tests assume our gcc version is concrete
        our_gcc_version = BinaryProvider.compiler_abi(platform_key_abi()).gcc_version
        @test our_gcc_version != :gcc_any

        # Get one that isn't us.
        other_gcc_version = :gcc4
        if our_gcc_version == other_gcc_version
            other_gcc_version = :gcc7
        end

        our_platform = platform_key_abi()
        other_platform = BinaryBuilder.replace_gcc_version(our_platform, other_gcc_version)
        fail_platform = BinaryBuilder.replace_gcc_version(our_platform, :gcc_any)
        
        # Build `hello` for our own platform, ensure it builds and runs:
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], our_platform)
        hello = ExecutableProduct(prefix, "hello", :hello)

        cd(joinpath(dirname(@__FILE__),"build_tests","fortran_hello")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build it
            @test build(ur, "hello", [hello], "make install", our_platform, prefix; verbose=true)

            # Ensure it's satisfied
            @test satisfied(hello; verbose=true)
        end

        # Ensure that we can actually run this `hello`:
        withenv(prefix) do
            @test success(`hello`)
        end
        rm(build_path, recursive = true)


        # Now, build one with not-our-GCC:
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], other_platform)
        hello = ExecutableProduct(prefix, "hello", :hello)
        cd(joinpath(dirname(@__FILE__),"build_tests","fortran_hello")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build it
            @test build(ur, "hello", [hello], "make install", other_platform, prefix; verbose=true)

            # Ensure it's satisfied (because `hello` exists, even if it can't run)
            @test satisfied(hello; verbose=true)
        end

        # Ensure that we can't actually run this `hello`:
        withenv(prefix) do
            @test !success(`hello`)
        end
        rm(build_path, recursive = true)

        # Finally, build with `:gcc_any`, which should throw because it needs to be gfortran-specific
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], fail_platform)
        hello = ExecutableProduct(prefix, "hello", :hello)
        cd(joinpath(dirname(@__FILE__),"build_tests","fortran_hello")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build it
            @test_warn "links to libgfortran!" !build(ur, "hello", [hello], "make install", fail_platform, prefix; verbose=true)
        end
        rm(build_path, recursive = true)
    end
end
