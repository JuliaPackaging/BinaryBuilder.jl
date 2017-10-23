using TerminalMenus

function yn_prompt(question, default = :y)
    @assert default in (:y, :n)
    while true
        print(question, " ", default == :y ? "[Y/n]" : "[y/N]", ": ")
        answer = lowercase(strip(readline()))
        if isempty(answer)
            return default
        elseif answer == "y" || answer == "yes"
            return :y
        elseif answer == "n" || answer == "no"
            return :n
        else
            println("Unrecognized answer. Answer `y` or `n`.")
        end
    end
end

function download_source(workspace, num)
    println("Please enter a URL (git repository or tarball) to obtain the source code from.")
    print("> ")
    url = readline()
    println()

    source_path = joinpath(workspace, "source-$num.tar.gz")

    download_cmd = gen_download_cmd(url, source_path)
    oc = OutputCollector(download_cmd; verbose=true)
    try
        if !wait(oc)
            error()
        end
    catch
        error("Could not download $(url) to $(workspace)")
    end

    source_path
end

function match_files(prefix, platform, files)
    # Collect all executable/library files
    prefix_files = collect_files(prefix)
    # Check if we can load them as an object file
    prefix_files = filter(prefix_files) do f
        try
            readmeta(f)
            return true
        catch
            return false
        end
    end

    # Normalize each file to only the filename, stripping extensions
    function normalize_name(file)
        file = basename(file)
        idx = findfirst(file, '.')
        if idx != 0
            return file[1:prevind(file, idx)]
        end
        return file
    end

    norm_prefix_files = Set(map(normalize_name, prefix_files))
    norm_files = Set(map(normalize_name, files))
    d = setdiff(norm_files, norm_prefix_files)
    if !isempty(d)
        warn("Could not find correspondences for $(join(d, ' '))")
    end
end

"""
Building large dependencies can take a lot of time. This state object captures
all relevant state of this function. It can be passed back to the function to
resume where we left off. This can aid debugging when code changes are necessary.
"""
mutable struct State
    step::Symbol
    # Filled in by step 1
    platforms::Union{Void, Vector{Platform}}
    # Filled in by step 2
    workspace::Union{Void, String}
    source_files::Union{Void, Vector{String}}
    # Filled in by step 3
    history::Union{Void, String}
    files::Union{Void, Vector{String}}
end

State() = State(:step1, nothing, nothing, nothing, nothing, nothing)

function step1(state)
    print_with_color(:bold, "\t\t\t\# Step 1: Select your platforms\n\n")

    platform_select = request("Make a platform selection",
        RadioMenu(["All supported architectures",
                   "Specific operating system",
                   "Specific architecture",
                   "Custom"]))

    println()

    if platform_select == 1
        state.platforms = supported_platforms()
    elseif platform_select == 2
        oses = sort(unique(map(typeof, supported_platforms())), by = repr)
        result = request("Select operating systems",
            MultiSelectMenu(map(repr, oses)))
        result = map(x->oses[x], result)
        state.platforms = collect(filter(x->typeof(x) in result, supported_platforms()))
    elseif platform_select == 3
        arches = sort(unique(map(arch, supported_platforms())), by = repr)
        result = request("Select architectures",
            MultiSelectMenu(map(repr, arches)))
        result = map(x->arches[x], result)
        state.platforms = collect(filter(x->arch(x) in result, supported_platforms()))
    elseif platform_select == 4
        platfs = supported_platforms()
        result = request("Select platforms",
            MultiSelectMenu(map(repr, platfs)))
        state.platforms = collect(map(x->platfs[x], result))
    else
        error("Fail")
    end

    println()
end

function step2(state)
    print_with_color(:bold, "\t\t\t\# Step 2: Obtain the source code\n\n")

    workspace = tempname()
    mkpath(workspace)

    state.source_files = String[]

    num = 1
    while true
        push!(state.source_files, download_source(workspace, num))
        println()
        num += 1
        yn_prompt("Would you like to download additional sources? ", :n) == :y || break
    end

    println()
end

function step34(state)
    print_with_color(:bold, "\t\t\t\# Step 3: Build for Linux x86_64\n\n")

    println("You will now be dropped into the cross-compilation environment.")
    println("Please compile the library. Your initial compilation target is Linux x86_64")
    println("The \$DESTDIR environment variable contains the target directory.")
    println("Many build systems will respect this variable automatically")
    println("Once you are done, exit by typing `exit` or `^D`")

    println()

    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        temp_prefix() do prefix
            histfile = joinpath(build_path, ".bash_history")
            dr = DockerRunner(prefix = prefix, platform = Linux(:x86_64),
                extra_env = Dict("HISTFILE" => histfile))
            for source in state.source_files
                unpack(source, build_path)
            end
            runshell(dr)

            # This is an extremely simplistic way to capture the history,
            # but ok for now. Obviously doesn't include any interactive
            # programs, etc.
            state.history = readstring(histfile)

            print_with_color(:bold, "\n\t\t\tBuild complete\n\n")
            print("Your build script was:\n\n\t")
            print(replace(state.history, "\n", "\n\t"))

            print_with_color(:bold, "\n\t\t\tAnalyzing...\n\n")

            audit(prefix; platform=Linux(:x86_64), verbose=true, autofix=false)

            println()
            print_with_color(:bold, "\t\t\t\# Step 4: Select build products\n\n")


            # Collect all executable/library files
            files = collect_files(prefix)
            # Check if we can load them as an object file
            files = filter(files) do f
                try
                    readmeta(f)
                    return true
                catch
                    return false
                end
            end

            state.files = map(file->replace(file, prefix.path, ""), files)
            if length(files) == 0
                # TODO: Make this a regular error path
                error("No build")
            elseif length(files) == 1
                println("The build has produced only one build artifact:\n")
                println("\t$(state.files[1])")
            else
                println("The build has produced several libraries and executables.")
                println("Please select which of these you want to consider `products`.")
                println("These are generally those artifacts you will load or use from julia.")

                state.files = map(x->state.files[x],collect(request("",
                    MultiSelectMenu(state.files))))
            end

            println()
        end
    end
end

function step5a(state)
    print_with_color(:bold, "\t\t\t\# Step 5: Generalize the build script\n\n")

    println("You have successfully built for Linux x86_64 (yay!).")
    println("We will now attempt to use the same script to build for other architectures.")
    println("This will likely fail, but the failure mode will help us understand why.")
    println()
    print("Your next build target will be ")
    print_with_color(:bold, "Win64")
    println(". This will help iron out any issues")
    println("with the cross compiler.")
    println()
    println("Press any key to continue...")
    read(STDIN, Char)
    println()

    print_with_color(:bold, "\t\t\t\# Attempting to build for Win64\n\n")

    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        temp_prefix() do prefix
            dr = DockerRunner(prefix = prefix, platform = Windows(:x86_64))
            for source in state.source_files
                unpack(source, build_path)
            end

            run(dr, `bash -c $(state.history)`, "/tmp/out.log"; verbose=true)

            print_with_color(:bold, "\n\t\t\tBuild complete. Analyzing...\n\n")

            audit(prefix; platform=Windows(:x86_64), verbose=true, autofix=false)

            match_files(prefix, Windows(:x86_64), state.files)
        end
    end

    println("")
    println("You have successfully built for Win64. Congratulations!")
    println()
end

function step5b(state)
    print("Your next build target will be Linux ")
    print_with_color(:bold, "AArch64")
    println(". This should uncover issues related")
    println("to architecture differences.")
    println()
    println("Press any key to continue...")
    read(STDIN, Char)
    println()

    print_with_color(:bold, "\t\t\t\# Attempting to build for Linux AArch64\n\n")

    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        temp_prefix() do prefix
            dr = DockerRunner(prefix = prefix, platform = Linux(:aarch64))
            for source in state.source_files
                unpack(source, build_path)
            end

            run(dr, `bash -c $(state.history)`, "/tmp/out.log"; verbose=true)

            print_with_color(:bold, "\n\t\t\tBuild complete. Analyzing...\n\n")

            audit(prefix; platform=Linux(:aarch64), verbose=true, autofix=false)

            match_files(prefix, Linux(:aarch64), state.files)
        end
    end

    println("")
    println("You have successfully built for Linux AArch64. Congratulations!")
    println()
end

function step5c(state)
    println("We will now attempt to build all remaining architectures.")
    println("Note that these builds are not verbose.")
    println("This will probably take a while.")
    println()
    println("Press any key to continue...")
    read(STDIN, Char)
    println()

    for platform in filter(x->!(x in (Linux(:x86_64), Linux(:aarch64), Windows(:x86_64))),
            state.platforms)
        print("Building $platform ")
        build_path = tempname()
        mkpath(build_path)
        cd(build_path) do
            temp_prefix() do prefix
                dr = DockerRunner(prefix = prefix, platform = platform)
                for source in state.source_files
                    unpack(source, build_path)
                end

                run(dr, `bash -c $(state.history)`, "/tmp/out.log"; verbose=false)

                audit(prefix; platform=platform, verbose=false, autofix=false)

                match_files(prefix, platform, state.files)
            end
        end
        print("[")
        print_with_color(:green, "✓")
        println("]")
    end
end

function run_wizard(state = State())
    println("Welcome to the BinaryBuilder wizard.\n"*
            "We'll get you set up in no time.\n")

    try
        while state.step != :done
            if state.step == :step1
                step1(state)
                state.step = :step2
            elseif state.step == :step2
                step2(state)
                state.step = :step3
            elseif state.step == :step3
                step34(state)
                state.step = :step5a
            elseif state.step == :step5a
                step5a(state)
                state.step = :step5b
            elseif state.step == :step5b
                step5b(state)
                state.step = :step5c
            elseif state.step == :step5c
                step5c(state)
                state.step = :done
            end
        end
    catch err
        bt = catch_backtrace()
        Base.showerror(STDERR, err, bt)
        println("\n")
        return state
    end

    print_with_color(:bold, "\t\t\tDone!\n\n")

    print("Your build script was:\n\n\t")
    print(replace(state.history, "\n", "\n\t"))

    nothing
end
