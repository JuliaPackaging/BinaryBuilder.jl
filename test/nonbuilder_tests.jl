# This file contains tests that are run no matter what, on every platform/
# environment that do not depend on docker or other methods of actually running
# our cross-compilation environment.

const bash = BinDeps2.gen_bash_cmd

@testset "OutputCollector" begin
    cd("output_tests") do
        # Collect the output of `simple.sh``
        oc = BinDeps2.OutputCollector(bash(`./simple.sh`))

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
        oc = BinDeps2.OutputCollector(bash(`./long.sh`))

        # Test that it worked, we can read it, and tail() works
        @test BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == long_out
        @test BinDeps2.tail(oc; len=10) == join(["$(idx)\n" for idx in 91:100], "")
    end

    # Next, test a command that fails
    cd("output_tests") do
        oc = BinDeps2.OutputCollector(bash(`./fail.sh`))

        @test !BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == "1\n2\n"
    end

    # Next, test a command that kills itself
    cd("output_tests") do
        oc = BinDeps2.OutputCollector(bash(`./kill.sh`))

        @test !BinDeps2.wait(oc)
        @test BinDeps2.merge(oc) == "1\n2\n"
    end

    # Next, test reading the output of a pipeline()
    grepline = pipeline(bash(`-c 'printf "Hello\nWorld\nJulia"'`), `grep ul`)
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
        @test success(bash(`prefix_path_test.sh`))
        
        # Now deactivate and make sure that all traces are gone
        BinDeps2.deactivate(prefix)
        @test BinDeps2.split_PATH()[1] != BinDeps2.bindir(prefix)
        @test Libdl.DL_LOAD_PATH[1] != BinDeps2.libdir(prefix)
    end
end

@testset "Packaging" begin
    # Clear out previous build products
    for f in readdir(".")
        if !endswith(f, ".tar.gz")
            continue
        end
        rm(f; force=true)
    end
    
    # Gotta set this guy up beforehand
    tarball_path = nothing

    BinDeps2.temp_prefix() do prefix
        # Create random files
        mkpath(joinpath(BinDeps2.bindir(prefix)))
        mkpath(joinpath(BinDeps2.libdir(prefix)))
        bar_path = joinpath(BinDeps2.bindir(prefix), "bar.sh")
        open(bar_path, "w") do f
            write(f, "#!/bin/bash\n")
            write(f, "echo yolo\n")
        end
        baz_path = joinpath(BinDeps2.libdir(prefix), "baz.so")
        open(baz_path, "w") do f
            write(f, "this is not an actual .so\n")
        end
        
        # Next, package it up as a .tar.gz file
        tarball_path = BinDeps2.package(prefix, "./libfoo"; verbose=true)
        @test isfile(tarball_path)

        # Test that packaging into a file that already exists fails
        @test_throws ErrorException BinDeps2.package(prefix, "./libfoo")
    end

    tarball_hash = open(tarball_path, "r") do f
        bytes2hex(sha256(f))
    end

    # Test that we can inspect the contents of the tarball
    contents = BinDeps2.list_tarball_files(tarball_path)
    @test "bin/bar.sh" in contents
    @test "lib/baz.so" in contents

    # Install it within a new Prefix
    BinDeps2.temp_prefix() do prefix
        # Install the thing
        @test BinDeps2.install(tarball_path, tarball_hash; prefix=prefix, verbose=true)

        # Ensure we can use it
        bar_path = joinpath(BinDeps2.bindir(prefix), "bar.sh")
        baz_path = joinpath(BinDeps2.libdir(prefix), "baz.so")

        # Ask for the manifest that contains these files to ensure it works
        manifest_path = BinDeps2.manifest_for_file(bar_path; prefix=prefix)
        @test isfile(manifest_path)
        manifest_path = BinDeps2.manifest_for_file(baz_path; prefix=prefix)
        @test isfile(manifest_path)

        # Ensure that manifest_for_file doesn't work on nonexistant files
        @test_throws ErrorException BinDeps2.manifest_for_file("nonexistant"; prefix=prefix)

        # Ensure that manifest_for_file doesn't work on orphan files
        orphan_path = joinpath(BinDeps2.bindir(prefix), "orphan_file")
        touch(orphan_path)
        @test isfile(orphan_path)
        @test_throws ErrorException BinDeps2.manifest_for_file(orphan_path; prefix=prefix)

        # Ensure that trying to install again over our existing files is an error
        @test_throws ErrorException BinDeps2.install(tarball_path, tarball_path; prefix=prefix)

        # Ensure we can uninstall this tarball
        @test BinDeps2.uninstall(manifest_path; verbose=true)
        @test !isfile(bar_path)
        @test !isfile(baz_path)
        @test !isfile(manifest_path)

        # Ensure that we don't want to install tarballs from other platforms
        cp(tarball_path, "./libfoo_juliaos64.tar.gz")
        @test_throws ErrorException BinDeps2.install("./libfoo_juliaos64.tar.gz", tarball_hash; prefix=prefix)
        rm("./libfoo_juliaos64.tar.gz"; force=true)

        # Ensure that hash mismatches throw errors
        fake_hash = reverse(tarball_hash)
        @test_throws ErrorException BinDeps2.install(tarball_path, fake_hash; prefix=prefix)
    end

    rm(tarball_path; force=true)
end


# Use ./build_libfoo_tarball.jl to generate more of these
small_bin_prefix = "https://github.com/staticfloat/small_bin/raw/94584567f67b7cd08e4f7bc36f62966ee22cea19/"
libfoo_downloads = Dict(
    :mac64 => ("$small_bin_prefix/libfoo_mac64.tar.gz",
               "87e3926840af3e47a1b4743c2786807a565495738d222d8ce0e865ed9498b5b8"),
    :linux64 => ("$small_bin_prefix/libfoo_linux64.tar.gz",
                 "072e6d7caa2f4009dd0cd831eb041cbf40ba0c3a4f1ea748e76d77463fbb4f12"),
    :linuxaarch64 => ("$small_bin_prefix/libfoo_linuxaarch64.tar.gz",
                 "634f38967ff8768393ce6c677814bbab596caa36ca565f82157cb3ccb79f2e1d"),
    :linuxppc64le => ("$small_bin_prefix/libfoo_linuxppc64le.tar.gz",
                 "cae66a63d82e2c81ace4619e84cf164c3f93118defe204b86f38b3616c674a50"),
    :linuxarmv7l => ("$small_bin_prefix/libfoo_linuxarmv7l.tar.gz",
                 "02950e8e8ac9053b37cb90e879621d26d6136805783ba65668615bf07c277e9f"),
)


@testset "Downloading" begin
    BinDeps2.temp_prefix() do prefix
        if !haskey(libfoo_downloads, platform)
            warn("Platform $platform does not have a libfoo download, skipping download tests")
        else
            # Test a good download works
            url, hash = libfoo_downloads[platform]
            @test BinDeps2.install(url, hash; prefix=prefix, verbose=true)

            BinDeps2.activate(prefix) do
                check_foo()
            end
        end

        # Test a bad download fails properly
        bad_url = "http://localhost:1/this_is_not_a_file_linux64.tar.gz"
        bad_hash = "0"^64
        @test_throws ErrorException BinDeps2.install(bad_url, bad_hash; prefix=prefix, verbose=true)
    end
end