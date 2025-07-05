using BinaryBuilder, BinaryBuilder.BinaryBuilderBase, BinaryBuilder.Wizard
using GitHub, Test, VT100, Sockets, HTTP, SHA, Tar
import Pkg: PackageSpec

import BinaryBuilder.BinaryBuilderBase: available_gcc_builds, available_llvm_builds, getversion

# cursor movement in the terminal
const UP = "\e[A"
const DOWN = "\e[B"
const RGHT = "\e[C"
const LEFR = "\e[D"

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
            # print(z)
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
io = IOBuffer()
Tar.create(joinpath(build_tests_dir, "libfoo"), pipeline(`gzip -9`, io))
libfoo_tarball_data = take!(io)
libfoo_tarball_hash = bytes2hex(sha256(libfoo_tarball_data))
function serve_tgz(req)
    HTTP.Response(200, libfoo_tarball_data)
end
@static if isdefined(HTTP, Symbol("@register"))
    HTTP.@register(r, "GET", "/*/source.tar.gz", serve_tgz)
else
    HTTP.register!(r, "GET", "/*/source.tar.gz", serve_tgz)
end
port = -1
server = Sockets.TCPServer()
# Try to connect to different ports, in case one is busy.  Important in case we
# have multiple parallel builds.
available_ports = 14444:14544
for i in available_ports
    try
        # Update the global server to shut it down when we are done with it.
        global server = Sockets.listen(Sockets.InetAddr(Sockets.localhost, i))
    catch e
        if e isa Base.IOError
            if i == last(available_ports)
                # Oh no, this was our last attempt
                error("No more ports available for the HTTP server")
            end
            # If the port is busy, try the next one
            continue
        else
            rethrow(e)
        end
    end
    # All looks good, update the global `port` and start the server
    global port = i
    @async HTTP.serve(r, Sockets.localhost, port; server=server, verbose=false)
    break
end

function readuntil_sift(io::IO, needle)
    # N.B.: This is a terrible way to do this and works around the fact that our `IOBuffer`
    # does not block. It works fine here, but do not copy this to other places.
    needle = codeunits(needle)
    buffer = zeros(UInt8, length(needle))
    all_buffer = UInt8[]
    while isopen(io)
        new_c = read(io, 1)
        append!(all_buffer, new_c)
        if isempty(new_c)
            # We need to wait for more data, sleep for a bit
            sleep(0.01)
            continue
        end

        buffer = [buffer[2:end]; new_c]
        if !any(buffer .!= needle)
            return all_buffer
        end
    end
    return nothing
end

function call_response(ins, outs, question, answer; newline=true)
    @assert readuntil_sift(outs, question) !== nothing
    # Because we occasionally are dealing with things that do strange
    # stdin tricks like reading raw stdin buffers, we sleep here for safety.
    sleep(0.1)
    print(ins, answer)
    if newline
        println(ins)
    end
end

@testset "Wizard - Obtain source" begin
    state = Wizard.WizardState()
    # Use a non existing name
    with_wizard_output(state, Wizard.get_name_and_version) do ins, outs
        # Append "_jll" to the name and make sure this is automatically removed
        call_response(ins, outs, "Enter a name for this project", "libfoobarqux_jll")
        call_response(ins, outs, "Enter a version number", "1.2.3")
    end
    @test state.name == "libfoobarqux"
    @test state.version == v"1.2.3"
    state.name = nothing
    # Use an existing name, choose a new one afterwards
    with_wizard_output(state, Wizard.get_name_and_version) do ins, outs
        call_response(ins, outs, "Enter a name for this project", "cuba")
        call_response(ins, outs, "Choose a new project name", "y")
        call_response(ins, outs, "Enter a name for this project", "libfoobarqux")
    end
    @test state.name == "libfoobarqux"
    @test state.version == v"1.2.3"
    state.name = nothing
    # Use an existing name, confirm the choice
    with_wizard_output(state, Wizard.get_name_and_version) do ins, outs
        call_response(ins, outs, "Enter a name for this project", "cuba")
        call_response(ins, outs, "Choose a new project name", "N")
    end
    @test state.name == "cuba"
    @test state.version == v"1.2.3"

    state = Wizard.WizardState()
    with_wizard_output(state, Wizard.step1) do ins, outs
        call_response(ins, outs, "Make a platform selection", "\r")
    end
    @test state.platforms == supported_platforms()

    state = Wizard.WizardState()
    with_wizard_output(state, Wizard.step1) do ins, outs
        call_response(ins, outs, "Make a platform selection", "$DOWN\r")
        call_response(ins, outs, "Select operating systems", "$DOWN\rd"; newline = false)
    end

    state = Wizard.WizardState()
    with_wizard_output(state, Wizard.step1) do ins, outs
        call_response(ins, outs, "Make a platform selection", "$DOWN$DOWN\r")
        call_response(ins, outs, "Select platforms", "$DOWN\rd"; newline = false)
    end
    @test length(state.platforms) == 1
end

# Set the state up
function step2_state()
    state = Wizard.WizardState()
    state.step = :step2
    state.platforms = [Platform("x86_64", "linux")]

    return state
end

@testset "Wizard - Downloading" begin
    state = step2_state()
    with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:$(port)/a/source.tar.gz")
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
        call_response(ins, outs, "Select the preferred LLVM version", "$DOWN$DOWN$DOWN\r")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == ["http://127.0.0.1:$(port)/a/source.tar.gz"]
    @test getfield.(state.source_files, :hash) == [libfoo_tarball_hash]
    @test Set(state.compilers) == Set([:c, :rust, :go])
    @test state.preferred_gcc_version == getversion(available_gcc_builds[1])
    # The default LLVM shard is the latest one, and above we pressed three times
    # arrow down in the reverse order list.
    @test state.preferred_llvm_version == getversion(available_llvm_builds[end-3])

    # Test two tar.gz download
    state = step2_state()
    with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:$(port)/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "Y")
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:$(port)/b/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "libfoo")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end
    # Check that the state is modified appropriately
    @test state.source_urls == [
        "http://127.0.0.1:$(port)/a/source.tar.gz",
        "http://127.0.0.1:$(port)/b/source.tar.gz",
    ]
    @test getfield.(state.source_files, :hash) == [
        libfoo_tarball_hash,
        libfoo_tarball_hash,
    ]

    #test that two files downloaded with the same name are re-named appropriately 
    m = match.(r"^.+(?=(\.tar\.([\s\S]+)))", basename.(getfield.(state.source_files,:path)))
    for cap in m
        @test cap.captures[1] ∈ BinaryBuilderBase.tar_extensions
    end

    # Test download/install with a broken symlink that used to kill the wizard
    # https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/183
    state = step2_state()
    with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")

        call_response(ins, outs, "Enter a name for this project", "broken_symlink")
        call_response(ins, outs, "Enter a version number", "1.0.0")

        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end

    # Test failure to resolve a dependency
    state = step2_state()
    @test_logs (:warn, r"Unable to resolve iso_codez_jll") match_mode=:any with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:$(port)/a/source.tar.gz")
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
    @test any([BinaryBuilder.getname(d) == "ghr_jll" for d in state.dependencies])
    @test any([BinaryBuilder.getname(d) == "Zlib_jll" for d in state.dependencies])

    # Test for escaping the URL prompt with N
    state = step2_state()
    with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "http://127.0.0.1:$(port)/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "Y")
        call_response(ins, outs, "Please enter a URL", "N")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")
        call_response(ins, outs, "Enter a name for this project", "get_me_out")
        call_response(ins, outs, "Enter a version number", "1.0.0")
        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end
    @test state.source_urls == ["http://127.0.0.1:$(port)/a/source.tar.gz"]
    state = step2_state()   
    with_wizard_output(state, Wizard.step2) do ins, outs
        call_response(ins, outs, "Please enter a URL", "N")
        call_response(ins, outs, "No URLs", "http://127.0.0.1:$(port)/a/source.tar.gz")
        call_response(ins, outs, "Would you like to download additional sources", "N")
        call_response(ins, outs, "Do you require any (binary) dependencies", "N")
        call_response(ins, outs, "Enter a name for this project", "no_urls")
        call_response(ins, outs, "Enter a version number", "1.0.0")
        call_response(ins, outs, "Do you want to customize the set of compilers?", "N")
    end
end

# Dump the tarball to disk so that we can use it directly in the future
tempspace = tempname()
mkdir(tempspace)
libfoo_tarball_path = joinpath(tempspace, "source.tar.gz")
open(f -> write(f, libfoo_tarball_data), libfoo_tarball_path, "w")

function step3_state()
    state = Wizard.WizardState()
    state.step = :step34
    state.platforms = [Platform("x86_64", "linux")]
    state.source_urls = ["http://127.0.0.1:$(port)/a/source.tar.gz"]
    state.source_files = [BinaryBuilder.SetupSource{ArchiveSource}(libfoo_tarball_path, libfoo_tarball_hash, "")]
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
    @test state.file_kinds[libfoo_idx] === :library
    @test state.file_kinds[fooifier_idx] === :executable
    @test state.file_varnames[libfoo_idx] === :libfoo
    @test state.file_varnames[fooifier_idx] === :fooifier
end

@testset "Wizard - Building" begin
    function succcess_path_call_response(ins, outs)
        output = readuntil_sift(outs, "Build complete")
        if contains(String(output), "Warning:")
            close(ins)
            return false
        end
        call_response(ins, outs, "Would you like to edit this script now?", "N")
        call_response(ins, outs, "d=done, a=all", "ad"; newline=false)
        call_response(ins, outs, "lib/libfoo.so", "libfoo")
        call_response(ins, outs, "bin/fooifier", "fooifier")
        return true
    end

    @testset "Test step3 success path" begin
        state = step3_state()
        with_wizard_output(state, Wizard.step34) do ins, outs
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            make install
            exit
            """)
            @test succcess_path_call_response(ins, outs)
        end
        @test state.history == """
        cd \$WORKSPACE/srcdir
        make install
        exit
        """
        step3_test(state)
    end

    @testset "Step 3 failure path (no binary in destdir -> return to build)" begin
        state = step3_state()
        with_wizard_output(state, Wizard.step34) do ins, outs
            # Don't build anything
            call_response(ins, outs, "\${WORKSPACE}/srcdir", "exit")
            call_response(ins, outs, "Would you like to edit this script now?", "N")

            # Return to build environment
            call_response(ins, outs, "Return to build environment", "\r", newline=false)
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            make install
            exit
            """)

            @test succcess_path_call_response(ins, outs)
        end
        @test state.history == """
        cd \$WORKSPACE/srcdir
        exit
        cd \$WORKSPACE/srcdir
        make install
        exit
        """
        step3_test(state)
    end

    @testset "Step 3 failure path (no binary in destdir -> retry with a clean build environment)" begin
        state = step3_state()
        with_wizard_output(state, Wizard.step34) do ins, outs
            # Don't build anything
            call_response(ins, outs, "\${WORKSPACE}/srcdir", "exit")
            call_response(ins, outs, "Would you like to edit this script now?", "N")

            # Clean environment
            call_response(ins, outs, "Return to build environment", "$DOWN\r")
        end
        @test state.step === :step3
    end

    @testset "Step 3 with a failing script" begin
        state = step3_state()
        with_wizard_output(state, Wizard.step34) do ins, outs
            # Build ok, but then indicate a failure
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            make install
            exit 1
            """)

            @test readuntil_sift(outs, "Warning:") !== nothing
            @test succcess_path_call_response(ins, outs)
        end
        step3_test(state)
    end

    @testset " Step 3 - retry" begin
        state = step3_state()
        # Build ok, but then indicate a failure
        with_wizard_output(state, Wizard.step34) do ins, outs
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            make install
            install_license LICENSE.md
            exit 1
            """)
            @test readuntil_sift(outs, "Warning:") !== nothing
            @test succcess_path_call_response(ins, outs)
        end
        with_wizard_output(state, Wizard.step3_retry) do ins, outs
            call_response(ins, outs, "bin/fooifier", "ad"; newline = false)
            call_response(ins, outs, "lib/libfoo", "libfoo")
            call_response(ins, outs, "bin/fooifier", "fooifier")
        end
        step3_test(state)
    end

    @testset "Step 3 dependency download" begin
        state = step3_state()
        state.dependencies = [Dependency(PackageSpec(name="Zlib_jll", uuid="83775a58-1f1d-513f-b197-d71354ab007a"))]
        with_wizard_output(state, Wizard.step34) do ins, outs
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            if [[ ! -f \${libdir}/libz.\${dlext} ]]; then
                echo "ERROR: Could not find libz.\${dlext}" >&2
                exit 1
            fi
            make install
            exit
            """)
            @test succcess_path_call_response(ins, outs)
        end
    end

    @testset " Step 3 - `bb add`" begin
        state = step3_state()
        state.dependencies = [Dependency(PackageSpec(name="Zlib_jll", uuid="83775a58-1f1d-513f-b197-d71354ab007a"))]
        with_wizard_output(state, Wizard.step34) do ins, outs
            call_response(ins, outs, "\${WORKSPACE}/srcdir", """
            if [[ ! -f \${libdir}/libz.\${dlext} ]]; then
                echo "ERROR: Could not find libz.\${dlext}" >&2
                exit 1
            fi
            bb add Xorg_xorgproto_jll
            if [[ ! -d \${includedir}/X11 ]]; then
                echo "ERROR: Could not find include/X11" >&2
                exit 1
            fi
            bb add Zlib_jll
            make install
            exit
            """)
            @test succcess_path_call_response(ins, outs)
        end
    end

end

function step5_state(script)
    state = step3_state()
    state.history = script
    state.files = ["lib/libfoo.so","bin/fooifier"]
    state.file_kinds = [:library, :executable]
    state.file_varnames = [:libfoo, :fooifier]
    state
end

@testset "Wizard - Generalizing" begin
    @testset "step5_internal (failure)" begin
        # Check that with a failing script, step 5 rejects,
        # even if all artifacts are present.
        state = step5_state("exit 1")
        with_wizard_output(state, state->Wizard.step5_internal(state, first(state.platforms))) do ins, outs
            call_response(ins, outs, "Press Enter to continue...", "\n")
            call_response(ins, outs, "How would you like to proceed?", "$DOWN$DOWN\r")
        end
        @test isempty(state.platforms)
    end

    @testset "step 5 sequence (failure)" begin
        state = step5_state("exit 1")
        empty!(state.platforms)

        Wizard.step5a(state)
        @test state.step === :step5b

        Wizard.step5b(state)
        @test state.step === :step5c
    end

    @testset "step 5 sequence (success)" begin
        state = step5_state("""
            cd \$WORKSPACE/srcdir
            make install
            install_license LICENSE.md
            exit 0
        """)

        with_wizard_output(state, Wizard.step5a) do ins, outs
            call_response(ins, outs, "Press Enter to continue...", "\n")
        end
        @test state.step === :step5b

        Wizard.step5b(state)
        @test state.step === :step5c

        with_wizard_output(state, Wizard.step5c) do ins, outs
            call_response(ins, outs, "Press Enter to continue...", "\n")
        end
    end
end

function step7_state()
    state = step5_state("""
        cd libfoos
        make install
        exit 1
    """)
    state.patches = [PatchSource("foo.patch", "this is a patch")]
    return state
end

@testset "Wizard - Deployment" begin
    state = step7_state()
    # First, test local deployment
    mktempdir() do out_dir
        with_wizard_output(state, state->Wizard._deploy(state)) do ins, outs
            call_response(ins, outs, "How should we deploy this build recipe?", "$DOWN\r")
            call_response(ins, outs, "Enter directory to write build_tarballs.jl to:", "$(out_dir)\r")
        end
        @test isfile(joinpath(out_dir, "build_tarballs.jl"))
        @test isfile(joinpath(out_dir, "bundled", "patches", "foo.patch"))
    end

    # Next, test writing out to stdout
    state = step7_state()
    with_wizard_output(state, state->Wizard._deploy(state)) do ins, outs
        call_response(ins, outs, "How should we deploy this build recipe?", "$DOWN$DOWN\r")
        @test readuntil_sift(outs, "Your generated build_tarballs.jl:") !== nothing
        @test readuntil_sift(outs, "name = \"libfoo\"") !== nothing
        @test readuntil_sift(outs, "make install") !== nothing
        @test readuntil_sift(outs, "LibraryProduct(\"libfoo\", :libfoo)") !== nothing
        @test readuntil_sift(outs, "ExecutableProduct(\"fooifier\", :fooifier)") !== nothing
        @test readuntil_sift(outs, "dependencies = Dependency[") !== nothing
    end
end

@testset "Wizard - state serialization" begin
    for state_generator in (Wizard.WizardState, step2_state, step3_state, step7_state)
        mktempdir() do dir
            state = state_generator()

            Wizard.save_wizard_state(state, dir)
            @test Wizard.load_wizard_state(dir; as_is=true) == state
        end
    end
end

@testset "Logo" begin
    io = PipeBuffer()
    Wizard.print_wizard_logo(io)
    @test contains(read(io, String), "https://github.com/JuliaPackaging/BinaryBuilder.jl")
end

close(server)

@testset "GitHub - authentication" begin
    withenv("GITHUB_TOKEN" => "") do
        @test Wizard.github_auth(allow_anonymous=true) isa GitHub.AnonymousAuth
    end
end
