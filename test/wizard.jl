using BinaryBuilder
using GitHub, Test, VT100, Sockets, HTTP, SHA
import Pkg

import BinaryBuilder: available_gcc_builds, available_llvm_builds, getversion, getpkg

function with_wizard_output(f::Function, state, step_func::Function)
    # Create fake terminal to communicate with BinaryBuilder over
    pty = VT100.create_pty(false)
    state.ins = Base.TTY(pty.slave)
    state.outs = Base.TTY(pty.slave)

    # Immediately start reading in off of `state.outs`
    out_buff = PipeBuffer()
    reader_task = @async begin
        while isopen(pty.master)
            z = String(readavailable(pty.master))

            # Un-comment this to figure out what on earth is going wrong
            #print(z)
            write(out_buff, z)
        end
    end

    # Start the wizard poppin' off
    wizard_task = @async begin
        try
            step_func(state)
        catch e
            bt = catch_backtrace()
            Base.display_error(stderr, e, bt)

            # If this fails, panic
            Test.@test false
        end
    end

    f(pty.master, out_buff)

    # Wait for the wizard to finish
    wait(wizard_task)

    # Once that's done, kill the reader task
    close(pty.master)
    wait(reader_task)
end

# Test the download stage
r = HTTP.Router()
build_tests_dir = joinpath(@__DIR__, "build_tests")
libfoo_tarball_data = read(`tar czf - -C $(build_tests_dir) libfoo`)
libfoo_tarball_hash = bytes2hex(sha256(libfoo_tarball_data))
function serve_tgz(req)
    HTTP.Response(200, libfoo_tarball_data)
end
HTTP.@register(r, "GET", "/*/source.tar.gz", serve_tgz)
@async HTTP.serve(r, Sockets.localhost, 14444; verbose=false)

function readuntil_sift(io::IO, needle)
    needle = codeunits(needle)
    buffer = zeros(UInt8, length(needle))
    while isopen(io)
        new_c = read(io, 1)
        if isempty(new_c)
            # We need to wait for more data, sleep for a bit
            sleep(0.01)
            continue
        end

        buffer = [buffer[2:end]; new_c]
        if !any(buffer .!= needle)
            return true
        end
    end
    return false
end

function call_response(ins, outs, question, answer; newline=true)
    @assert readuntil_sift(outs, question)
    # Because we occasionally are dealing with things that do strange
    # stdin tricks like reading raw stdin buffers, we sleep here for safety.
    sleep(0.1)
    print(ins, answer)
    if newline
        println(ins)
    end
end

# Set the state up
function step2_state()
    state = BinaryBuilder.WizardState()
    state.step = :step2
    state.platforms = [Linux(:x86_64)]

    return state
end

@testset "Wizard - Downloading" begin
    state = step2_state()
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "libfoo")

        # Test bad version number detection
        call_response(ins, outs, "Enter a version number", "parse me, I dare you")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        # Compiler
        call_response(ins, outs, "Do you want to customize the set of compilers?", "Y")
        call_response(ins, outs, "Select compilers for the project", "ad")
        call_response(ins, outs, "Select the preferred GCC version", "\r")
        call_response(ins, outs, "Select the preferred LLVM version", "\e[B\e[B\e[B\r")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == ["http://127.0.0.1:14444/a/source.tar.gz"]
    @test getfield.(state.source_files, :hash) == [libfoo_tarball_hash]
    @test Set(state.compilers) == Set([:c, :rust, :go])
    @test state.preferred_gcc_version == getversion(available_gcc_builds[1])
    # The default LLVM shard is the latest one, and above we pressed three times
    # arrow down in the reverse order list.
    @test state.preferred_llvm_version == getversion(BinaryBuilder.available_llvm_builds[end-3])

    # Test two tar.gz download
    state = step2_state()
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "Y")
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/b/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "libfoo")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == [
        "http://127.0.0.1:14444/a/source.tar.gz",
        "http://127.0.0.1:14444/b/source.tar.gz",
    ]
    @test getfield.(state.source_files, :hash) == [
        libfoo_tarball_hash,
        libfoo_tarball_hash,
    ]

    # Test download/install with a broken symlink that used to kill the wizard
    # https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/183
    state = step2_state()
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "broken_symlink")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end

    # Test failure to resolve a dependency
    state = step2_state()
    @test_logs (:warn, r"Unable to resolve iso_codez_jll") match_mode=:any with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "Y")

        call_response(ins, outs, "Enter JLL package name:", "ghr_jll")
        call_response(ins, outs, "Would you like to provide additional dependencies?", "Y")
        # Test auto-JLL suffixing
        call_response(ins, outs, "Enter JLL package name:", "Zlib")
        call_response(ins, outs, "Would you like to provide additional dependencies?", "Y")

        # Test typo detection
        call_response(ins, outs, "Enter JLL package name:", "iso_codez_jll")
        call_response(ins, outs, "Unable to resolve", "N")

        call_response(ins, outs, "Enter a name for this project", "check_deps")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end
    @test length(state.dependencies) == 2
    @test any([getpkg(d).name == "ghr_jll" for d in state.dependencies])
    @test any([getpkg(d).name == "Zlib_jll" for d in state.dependencies])
end



# Dump the tarball to disk so that we can use it directly in the future
tempspace = tempname()
mkdir(tempspace)
libfoo_tarball_path = joinpath(tempspace, "source.tar.gz")
open(f -> write(f, libfoo_tarball_data), libfoo_tarball_path, "w")



function step3_state()
    state = BinaryBuilder.WizardState()
    state.step = :step34
    state.platforms = [Linux(:x86_64)]
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz"]
    state.source_files = [BinaryBuilder.SetupSource(libfoo_tarball_path, libfoo_tarball_hash)]
    state.name = "libfoo"
    state.version = v"1.0.0"
    state.dependencies = Dependency[]
    state.compilers = [:c]
    state.preferred_gcc_version = getversion(available_gcc_builds[1])
    state.preferred_llvm_version = getversion(available_llvm_builds[end])

    return state
end

function step3_test(state)
    @test length(state.files) == 2
    @test "lib/libfoo.so" in state.files
    @test "bin/fooifier" in state.files

    libfoo_idx = findfirst(state.files .== "lib/libfoo.so")
    fooifier_idx = findfirst(state.files .== "bin/fooifier")
    @test state.file_kinds[libfoo_idx] == :library
    @test state.file_kinds[fooifier_idx] == :executable
    @test state.file_varnames[libfoo_idx] == :libfoo
    @test state.file_varnames[fooifier_idx] == :fooifier
end

@testset "Wizard - Building" begin
    # Test step3 success path
    state = step3_state()
    with_wizard_output(state, BinaryBuilder.step34) do ins, outs
        call_response(ins, outs, "\${WORKSPACE}/srcdir", """
        cd libfoo
        make install
        exit
        """)
        call_response(ins, outs, "Would you like to edit this script now?", "N")
        call_response(ins, outs, "d=done, a=all", "ad"; newline=false)
        call_response(ins, outs, "lib/libfoo.so:", "libfoo")
        call_response(ins, outs, "bin/fooifier:", "fooifier")
    end
    @test state.history == """
    cd \$WORKSPACE/srcdir
    cd libfoo
    make install
    exit
    """
    step3_test(state)

    # Step 3 failure path (no binary in destdir -> return to build)
    state = step3_state()
    with_wizard_output(state, BinaryBuilder.step34) do ins, outs
        # Don't build anything
        call_response(ins, outs, "\${WORKSPACE}/srcdir", "exit")
        call_response(ins, outs, "Would you like to edit this script now?", "N")

        # Return to build environment
        call_response(ins, outs, "Return to build environment", "\r", newline=false)
        call_response(ins, outs, "\${WORKSPACE}/srcdir", """
        cd libfoo
        make install
        exit
        """)

        call_response(ins, outs, "Would you like to edit this script now?", "N")
        call_response(ins, outs, "d=done, a=all", "ad"; newline=false)
        call_response(ins, outs, "lib/libfoo.so:", "libfoo")
        call_response(ins, outs, "bin/fooifier:", "fooifier")
    end
    @test state.history == """
    cd \$WORKSPACE/srcdir
    exit
    cd \$WORKSPACE/srcdir
    cd libfoo
    make install
    exit
    """
    step3_test(state)

    # Step 3 failure path (no binary in destdir -> retry with a clean build environment)
    state = step3_state()
    with_wizard_output(state, BinaryBuilder.step34) do ins, outs
        # Don't build anything
        call_response(ins, outs, "\${WORKSPACE}/srcdir", "exit")
        call_response(ins, outs, "Would you like to edit this script now?", "N")

        # Clean environment
        call_response(ins, outs, "Return to build environment", "\e[B\r")
    end
    @test state.step == :step3


    # Step 3 dependency download
    state = step3_state()
    state.dependencies = [Dependency(Pkg.PackageSpec(name="Zlib_jll", uuid="83775a58-1f1d-513f-b197-d71354ab007a"))]
    with_wizard_output(state, BinaryBuilder.step34) do ins, outs
        call_response(ins, outs, "\${WORKSPACE}/srcdir", """
        if [[ ! -f \${libdir}/libz.\${dlext} ]]; then
            echo "ERROR: Could not find libz.\${dlext}" >&2
            exit 1
        fi
        cd libfoo
        make install
        exit
        """)
        call_response(ins, outs, "Would you like to edit this script now?", "N")
        call_response(ins, outs, "d=done, a=all", "ad"; newline=false)
        call_response(ins, outs, "lib/libfoo.so:", "libfoo")
        call_response(ins, outs, "bin/fooifier:", "fooifier")
    end
end

@testset "GitHub - authentication" begin
    withenv("GITHUB_TOKEN" => "") do
        @test BinaryBuilder.github_auth(allow_anonymous=true) isa GitHub.AnonymousAuth
        input_stream = IOBuffer()
        close(input_stream)
        @test_throws ErrorException BinaryBuilder.obtain_token(ins=input_stream)
    end
end
