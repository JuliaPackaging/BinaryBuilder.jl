using BinaryBuilder
using GitHub, Test, VT100, Sockets, HTTP, SHA
import Pkg

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
@testset "Wizard - Downloading" begin
    state = BinaryBuilder.WizardState()
    state.step = :step2
    state.platforms = [Linux(:x86_64)]
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "libfoo")
        call_response(ins, outs, "Enter a version number", "1.0.0")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == ["http://127.0.0.1:14444/a/source.tar.gz"]
    @test state.source_hashes == [libfoo_tarball_hash]


    # Test two tar.gz download
    state = BinaryBuilder.WizardState()
    state.step = :step2
    state.platforms = [Linux(:x86_64)]
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "Y")
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:14444/b/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "libfoo")
        call_response(ins, outs, "Enter a version number", "1.0.0")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == [
        "http://127.0.0.1:14444/a/source.tar.gz",
        "http://127.0.0.1:14444/b/source.tar.gz",
    ]
    @test state.source_hashes == [
        libfoo_tarball_hash,
        libfoo_tarball_hash,
    ]

    # Test download/install with a broken symlink that used to kill the wizard
    # https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/183
    state = BinaryBuilder.WizardState()
    state.step = :step2
    state.platforms = [Linux(:x86_64)]
    with_wizard_output(state, BinaryBuilder.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "broken_symlink")
        call_response(ins, outs, "Enter a version number", "1.0.0")
    end
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
    state.source_files = [libfoo_tarball_path]
    state.source_hashes = [libfoo_tarball_hash]
    state.name = "libfoo"
    state.version = v"1.0.0"
    state.dependencies = String[]

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



    # These technically should wait until the terminal has been put into/come out
    # of raw mode.  We could probably detect that, but good enough for now.
    #wait_for_menu(pty) = sleep(0.1)
    #wait_for_non_menu(pty) = sleep(1)

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
    state.dependencies = ["Zlib_jll"]
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
    end
end
