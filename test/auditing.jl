# Tests for our auditing infrastructure

@testset "Auditor - ISA tests" begin
    begin
        build_path = tempname()
        mkpath(build_path)
        isa_platform = Linux(:x86_64)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], isa_platform)

        main_sse = ExecutableProduct(prefix, "main_sse", :main_sse)
        main_avx = ExecutableProduct(prefix, "main_avx", :main_avx)
        main_avx2 = ExecutableProduct(prefix, "main_avx2", :main_avx2)
        products = [main_sse, main_avx, main_avx2]

        cd(joinpath(dirname(@__FILE__),"build_tests","isa_tests")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # Build isa tests
            script="""
            /usr/bin/make clean
            /usr/bin/make install
            """

            # Build it
            @test build(ur, "isa_tests", products, script, isa_platform, prefix; verbose=true)

            # Ensure it's satisfied
            @test all(satisfied(r; verbose=true) for r in products)
        end

        # Next, test isa of these files
        readmeta(locate(main_sse)) do oh
            isa_sse = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_sse == :core2
        end

        readmeta(locate(main_avx)) do oh
            isa_avx = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_avx == :sandybridge
        end

        readmeta(locate(main_avx2)) do oh
            isa_avx2 = BinaryBuilder.analyze_instruction_set(oh; verbose=true)
            @test isa_avx2 == :haswell
        end

        # Delete the build path
        rm(build_path, recursive = true)
    end
end

@testset "Auditor - .dll moving" begin
    begin
        build_path = tempname()
        mkpath(build_path)
        dll_platform = Windows(:x86_64)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], dll_platform)
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # First, build libfoo, but with a dumb script that doesn't know to put .dll files in bin
            dumb_script = """
            /usr/bin/make clean
            /usr/bin/make install libdir=\$prefix/lib
            """

            @test build(ur, "foo", libfoo_products(prefix), libfoo_script, dll_platform, prefix; autofix=false)
        end

        # Test that libfoo puts its .dll's into lib, even on windows:
        @test !isfile(joinpath(prefix, "bin", "libfoo.dll"))
        @test isfile(joinpath(prefix, "lib", "libfoo.dll"))

        # Test that `audit()` moves it to `bin`.
        BinaryBuilder.audit(prefix; platform=dll_platform, verbose=true, autofix=true)
        @test isfile(joinpath(prefix, "bin", "libfoo.dll"))
        @test !isfile(joinpath(prefix, "lib", "libfoo.dll"))
    end
end

@testset "Auditor - absolute paths" begin
    prefix = Prefix(tempname())
    try
        sharedir = joinpath(prefix.path, "share")
        mkpath(sharedir)
        open(joinpath(sharedir, "foo.conf"), "w") do f
            write(f, "share_dir = \"$sharedir\"")
        end

        # Test that `audit()` warns about an absolute path within the prefix
        @test_warn "share/foo.conf" BinaryBuilder.audit(prefix)
    finally
        rm(prefix.path; recursive=true)
    end
end

