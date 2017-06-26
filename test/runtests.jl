using BinDeps2
using Base.Test
using SHA

# Output of a few scripts we are going to run
const simple_out = "1\n2\n3\n4\n"
const long_out = join(["$(idx)\n" for idx in 1:100], "")

# We are going to build libfoo a lot, so here's our function to make sure the
# library is working properly
function check_foo(fooifier_path, libfoo_path)
    # We know that foo(a, b) returns 2*a^2 - b
    result = 2*2.2^2 - 1.1

    # Test that we can invoke fooifier
    @test !success(`$fooifier_path`)
    @test success(`$fooifier_path 1.5 2.0`)
    @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

    # Test that we can dlopen() libfoo and invoke it directly
    libfoo = Libdl.dlopen_e(libfoo_path)
    @test libfoo != C_NULL
    foo = Libdl.dlsym_e(libfoo, :foo)
    @test foo != C_NULL
    @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
    Libdl.dlclose(libfoo)
end




@testset "OutputCollector" begin
    cd("output_tests") do
        # Collect the output of `simple.sh``
        oc = BinDeps2.OutputCollector(`./simple.sh`)

        # Ensure we can wait on it and it exited properly
        @test BinDeps2.wait(oc)

        # Ensure further waits are fast and still return 0
        let
            tstart = time()
            @test BinDeps2.wait(oc)
            @test time() - tstart < 0.1
        end

        # Test that we can merge properly
        @test BinDeps2.merge(oc) == simple_out

        # Test that merging twice works
        @test BinDeps2.merge(oc) == simple_out

        # Test that `tail()` gives the same output as well
        @test BinDeps2.tail(oc) == simple_out

        # Test that colorization works
        let
            red = Base.text_colors[:red]
            def = Base.text_colors[:default]
            gt = "1\n$(red)2\n$(def)3\n4\n"
            @test BinDeps2.merge(oc; colored=true) == gt
            @test BinDeps2.tail(oc; colored=true) == gt
        end

        # Test that we can grab stdout and stderr separately
        @test BinDeps2.stdout(oc) == "1\n3\n4\n"
        @test BinDeps2.stderr(oc) == "2\n"
    end

    # Next test a much longer output program
    cd("output_tests") do
        oc = BinDeps2.OutputCollector(`./long.sh`)

        # Test that it worked, we can read it, and tail() works
        @test BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == long_out
        @test BinDeps2.tail(oc; len=10) == join(["$(idx)\n" for idx in 91:100], "")
    end

    # Next, test a command that fails
    cd("output_tests") do
        oc = BinDeps2.OutputCollector(`./fail.sh`)

        @test !BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == "1\n2\n"
    end

    # Next, test a command that kills itself
    cd("output_tests") do
        oc = BinDeps2.OutputCollector(`./kill.sh`)

        @test !BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == "1\n2\n3\n"
    end

    # Next, test reading the output of a pipeline()
    grepline = pipeline(`printf "Hello\nWorld\nJulia"`, `grep ul`)
    oc = BinDeps2.OutputCollector(grepline)

    @test BinDeps2.wait(oc)
    @test BinDeps2.merge(oc) == "Julia\n"
end

@testset "Prefix" begin
    mktempdir() do temp_dir
        prefix = BinDeps2.Prefix(temp_dir)

        # Test that it's taking the absolute path
        @test prefix.path == abspath(temp_dir)

        # Test that `bindir()` works
        mkpath(joinpath(BinDeps2.bindir(prefix)))
        @test isdir(joinpath(BinDeps2.bindir(prefix)))

        # Create a little script within the bindir to ensure we can run it
        ppt_path = joinpath(BinDeps2.bindir(prefix), "prefix_path_test.sh")
        open(ppt_path, "w") do f
            write(f, "#!/bin/bash\n")
            write(f, "echo yolo\n")
        end
        chmod(ppt_path, 0o775)

        # Test that activation adds certain paths to our environment variables
        BinDeps2.activate(prefix)

        # PATH[1] should be "<prefix>/bin" now
        @test BinDeps2.split_PATH()[1] == BinDeps2.bindir(prefix)
        @test Libdl.DL_LOAD_PATH[1] == BinDeps2.libdir(prefix)

        # Test we can run the script we dropped within this prefix
        @test success(`prefix_path_test.sh`)
        
        # Now deactivate and make sure that all traces are gone
        BinDeps2.deactivate(prefix)
        @test BinDeps2.split_PATH()[1] != BinDeps2.bindir(prefix)
        @test Libdl.DL_LOAD_PATH[1] != BinDeps2.libdir(prefix)
    end
end

@testset "BuildStep" begin
    BinDeps2.temp_prefix() do prefix
        cd("output_tests") do
            bs = BinDeps2.BuildStep("simple", `./simple.sh`, prefix)
            @test BinDeps2.build(bs)
            @test readstring(BinDeps2.logpath(bs)) == "1\n2\n3\n4\n"

            bs = BinDeps2.BuildStep("long", `./long.sh`, prefix)
            @test BinDeps2.build(bs)
            @test readstring(BinDeps2.logpath(bs)) == long_out
            
            # Show what it looks like for something to fail/get killed
            info("Expecting the following two BuildSteps to fail...")
            bs = BinDeps2.BuildStep("fail", `./fail.sh`, prefix)
            @test !BinDeps2.build(bs)
            bs = BinDeps2.BuildStep("kill", `./kill.sh`, prefix)
            @test !BinDeps2.build(bs)
        end
    end
end

@testset "Dependency" begin
    BinDeps2.temp_prefix() do prefix
        # First, let's create a Dependency that just installs a file
        cd("build_tests") do
            # Our simple executable file, generated by bash
            test_exe = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix),"test_exe"))
            results = [test_exe]

            cmds = Cmd[]
            push!(cmds, `mkdir -p $(BinDeps2.bindir(prefix))`)
            push!(cmds, `bash -c "printf '#!/bin/bash\necho test' > $(test_exe.path)"`)
            push!(cmds, `chmod 775 $(test_exe.path)`)
            
            dep = BinDeps2.Dependency("bash_test", results, cmds, prefix)

            @test BinDeps2.build(dep; verbose=true)
            @test BinDeps2.satisfied(dep)
            @test readstring(`$(test_exe.path)`) == "test\n"
        end

        # Next, build a simple shared library and an executable
        cd("build_tests/libfoo") do
            libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(prefix), "libfoo"))
            fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix), "fooifier"))
            dep = BinDeps2.Dependency("foo", [libfoo, fooifier], [`make install`], prefix)

            # Build it
            @test BinDeps2.build(dep; verbose=true)
            @test BinDeps2.satisfied(dep; verbose=true)

            # Test the binaries
            check_foo(fooifier.path, libfoo.path)
        end
    end

    BinDeps2.temp_prefix() do prefix
        # Next, work in two layers of dependencies.  We'll build `libfoo` just like
        # above, but we'll explicitly model `fooifier` as a separate, Dependency
        cd("build_tests/libfoo") do
            libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(prefix), "libfoo"))
            cmds = [`make install-libfoo`]
            dep_libfoo = BinDeps2.Dependency("libfoo", [libfoo], cmds, prefix)

            fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(prefix), "fooifier"))
            cmds = [`make install-fooifier`]
            dep_fooifier = BinDeps2.Dependency("fooifier", [fooifier], cmds, prefix, [dep_libfoo])

            # Build fooifier, which should invoke libfoo automagically
            @test BinDeps2.build(dep_fooifier; verbose=true)

            # Test the binaries
            check_foo(fooifier.path, libfoo.path)

            # Make sure once it's built, it doesn't auto-build again
            info("The following two builds should not need to be run")
            BinDeps2.build(dep_fooifier; verbose=true)
        end
    end
end

@testset "Packaging" begin
    # Clear out previous build products
    rm("./libfoo.tar.gz"; force=true)

    # Gotta set this guy up beforehand
    libfoo_hash = nothing

    BinDeps2.temp_prefix() do build_prefix
        cd("build_tests/libfoo") do
            # First, build libfoo
            libfoo = BinDeps2.LibraryResult(joinpath(BinDeps2.libdir(build_prefix), "libfoo"))
            fooifier = BinDeps2.FileResult(joinpath(BinDeps2.bindir(build_prefix), "fooifier"))
            dep = BinDeps2.Dependency("foo", [libfoo, fooifier], [`make install`], build_prefix)

            @test BinDeps2.build(dep)
        end    
        
        # Next, package it up as a .tar.gz file
        BinDeps2.package(build_prefix, "./libfoo.tar.gz"; verbose=true)
        @test isfile("./libfoo.tar.gz")
        libfoo_hash = open("./libfoo.tar.gz", "r") do f
            bytes2hex(sha256(f))
        end

        # Test that packaging into a file that already exists fails
        @test_throws ErrorException BinDeps2.package(build_prefix, "./libfoo.tar.gz")
    end

    # Test that we can inspect the contents of the tarball
    contents = BinDeps2.list_tarball_files("./libfoo.tar.gz")
    @test "bin/fooifier" in contents

    # Install it within a new Prefix
    rm("./libfoo_install_prefix"; force=true, recursive=true)
    install_prefix = BinDeps2.Prefix("./libfoo_install_prefix")
    BinDeps2.install(install_prefix, "./libfoo.tar.gz", libfoo_hash; verbose=true)

    # Ensure we can use it
    fooifier_path = joinpath(BinDeps2.bindir(install_prefix), "fooifier")
    libfoo_path = joinpath(BinDeps2.libdir(install_prefix), "libfoo.$(Libdl.dlext)")
    check_foo(fooifier_path, libfoo_path)

    # Ask for the manifest that contains these files to ensure it works
    manifest_path = BinDeps2.manifest_for_file(install_prefix, fooifier_path)
    @test isfile(manifest_path)
    manifest_path = BinDeps2.manifest_for_file(install_prefix, libfoo_path)
    @test isfile(manifest_path)

    # Ensure that manifest_for_file doesn't work on nonexistant files
    @test_throws ErrorException BinDeps2.manifest_for_file(install_prefix, "nonexistant")

    # Ensure that manifest_for_file doesn't work on orphan files
    orphan_path = joinpath(BinDeps2.bindir(install_prefix), "orphan_file")
    touch(orphan_path)
    @test isfile(orphan_path)
    @test_throws ErrorException BinDeps2.manifest_for_file(install_prefix, orphan_path)

    # Ensure we can uninstall libfoo
    @test BinDeps2.uninstall(install_prefix, manifest_path; verbose=true)
    @test !isfile(fooifier_path)
    @test !isfile(libfoo_path)
    @test !isfile(manifest_path)

    rm("./libfoo_install_prefix"; force=true, recursive=true)
    rm("./libfoo.tar.gz"; force=true)
end


# TODO
# Test downloading
# Test overwriting when installing
# Ensure hashing fails properly
# More auditing
# Ensure auditing fails