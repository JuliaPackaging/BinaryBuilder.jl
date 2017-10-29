using TerminalMenus

function yn_prompt(state, question, default = :y)
    @assert default in (:y, :n)
    while true
        print(state.outs,
            question, " ", default == :y ? "[Y/n]" : "[y/N]", ": ")
        answer = lowercase(strip(readline(state.ins)))
        if isempty(answer)
            return default
        elseif answer == "y" || answer == "yes"
            return :y
        elseif answer == "n" || answer == "no"
            return :n
        else
            println(state.outs,
                "Unrecognized answer. Answer `y` or `n`.")
        end
    end
end

function download_source(state, workspace, num)
    println(state.outs, "Please enter a URL (git repository or tarball) to obtain the source code from.")
    print(state.outs, "> ")
    url = readline(state.ins)
    println(state.outs)

    source_path = joinpath(workspace, "source-$num.tar.gz")

    download_cmd = gen_download_cmd(url, source_path)
    oc = OutputCollector(download_cmd; verbose=true, tee_stream=state.outs)
    try
        if !wait(oc)
            error()
        end
    catch
        error("Could not download $(url) to $(workspace)")
    end

    local source_hash
    open(source_path) do file
        source_hash = bytes2hex(BinaryProvider.sha256(file))
    end

    url, source_path, source_hash
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

function match_files(prefix, platform, files)
    # Collect all executable/library files
    prefix_files = collapse_symlinks(collect_files(prefix))
    # Check if we can load them as an object file
    prefix_files = filter(prefix_files) do f
        try
            readmeta(f)
            return true
        catch
            return false
        end
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
    ins::IO
    outs::IO
    # Filled in by step 1
    platforms::Union{Void, Vector{Platform}}
    # Filled in by step 2
    workspace::Union{Void, String}
    source_urls::Union{Void, Vector{String}}
    source_files::Union{Void, Vector{String}}
    source_hashes::Union{Void, Vector{String}}
    # Filled in by step 3
    history::Union{Void, String}
    files::Union{Void, Vector{String}}
    file_kinds::Union{Void, Vector{Symbol}}
end

State() = State(:step1, STDIN, STDOUT, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)

function step1(state)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 1: Select your platforms\n\n")

    terminal = Base.Terminals.TTYTerminal("xterm", state.ins, state.outs, state.outs)

    platform_select = request(terminal,
        "Make a platform selection",
        RadioMenu(["All supported architectures",
                   "Specific operating system",
                   "Specific architecture",
                   "Custom"]))

    println(state.outs)

    if platform_select == 1
        state.platforms = supported_platforms()
    elseif platform_select == 2
        oses = sort(unique(map(typeof, supported_platforms())), by = repr)
        result = request(terminal,
            "Select operating systems",
            MultiSelectMenu(map(repr, oses)))
        result = map(x->oses[x], result)
        state.platforms = collect(filter(x->typeof(x) in result, supported_platforms()))
    elseif platform_select == 3
        arches = sort(unique(map(arch, supported_platforms())), by = repr)
        result = request(terminal,
            "Select architectures",
            MultiSelectMenu(map(repr, arches)))
        result = map(x->arches[x], result)
        state.platforms = collect(filter(x->arch(x) in result, supported_platforms()))
    elseif platform_select == 4
        platfs = supported_platforms()
        result = request(terminal,
            "Select platforms",
            MultiSelectMenu(map(repr, platfs)))
        state.platforms = collect(map(x->platfs[x], result))
    else
        error("Fail")
    end

    println(state.outs)
end

function step2(state)
    print_with_color(:bold, state.outs,
        "\t\t\t\# Step 2: Obtain the source code\n\n")

    workspace = tempname()
    mkpath(workspace)

    state.source_urls = String[]
    state.source_files = String[]
    state.source_hashes = String[]

    num = 1
    while true
        url, file, hash = download_source(state, workspace, num)
        push!(state.source_urls, url)
        push!(state.source_files, file)
        push!(state.source_hashes, hash)
        println(state.outs)
        num += 1
        yn_prompt(state,
            "Would you like to download additional sources? ", :n) == :y || break
    end

    println(state.outs)
end

function provide_hints(state, path)
    files = readdir(path)
    println(state.outs,
        "You have the following contents in your working directory:")
    println(state.outs, join(map(x->string("  - ", x),files),'\n'))
    print_with_color(:yellow, state.outs, "Hints:\n")
    for (root, dirs, files) in walkdir(path)
        for file in files
            file_path = joinpath(root, file)
            if file == "configure" && contains(
                    readstring(file_path), "Generated by GNU Autoconf")
                println(state.outs, "  - ", replace(file_path, "$path/", ""), "\n")
                println(state.outs, "    This file is a configure file generated by GNU Autoconf. The recommended")
                print(  state.outs, "    options for GNU Autoconf are `")
                print_with_color(:bold, state.outs, "./configure --prefix=/ --host=\$target")
                println(state.outs, "`")
                println(state.outs, "    followed by `make` and `make install`. Since the DESTDIR environment")
                println(state.outs, "    variable is set already, this will automatically perform the installation")
                println(state.outs, "    into the correct directory.\n")
            end
        end
    end
end

function setup_workspace(build_path, src_paths, platform, extra_env=Dict{String, String}(); verbose=false)
    # Use a random nonce to make detection of paths in embedded binary
    # easier.
    nonce = randstring()
    mkdir(nonce); cd(nonce)

    # We now set up two directories here, one as a source dir, one as
    # a dest dir
    mkdir("srcdir"); mkdir("destdir");

    # Unpack the sources into the srcdir
    for src_path in src_paths
        unpack(src_path, "srcdir")
    end

    prefix = Prefix(joinpath(pwd(), "destdir"))

    ur = UserNSRunner(
        workspace = build_path,
        cwd = "/workspace/$nonce/srcdir",
        platform = Linux(:x86_64),
        extra_env = merge(extra_env,
            Dict("DESTDIR" => "/workspace/$nonce/destdir",
                 "WORKSPACE" => "/workspace/$nonce")))

    prefix, ur
end

function step34(state)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 3: Build for Linux x86_64\n\n")

    println(state.outs, "You will now be dropped into the cross-compilation environment.")
    println(state.outs, "Please compile the library. Your initial compilation target is Linux x86_64")
    println(state.outs, "The \$DESTDIR environment variable contains the target directory.")
    println(state.outs, "Many build systems will respect this variable automatically")
    println(state.outs, "Once you are done, exit by typing `exit` or `^D`")

    println(state.outs)

    build_path = tempname()
    mkpath(build_path)
    history = ""
    cd(build_path) do
        histfile = joinpath(build_path, ".bash_history")
        prefix, ur = setup_workspace(build_path, state.source_files, Linux(:x86_64),
            Dict("HISTFILE"=>"/workspace/.bash_history"))
        provide_hints(state, joinpath(pwd(), "srcdir"))

        while true
            runshell(ur, state.ins, state.outs, state.outs)

            # This is an extremely simplistic way to capture the history,
            # but ok for now. Obviously doesn't include any interactive
            # programs, etc.
            if isfile(histfile)
                history = string(history,
                    # This is a bit of a hack for now to get around the fact
                    # that we don't know cwd when we get back from bash, but
                    # always start in the WORKSPACE. This makes sure the script
                    # accurately reflects that.
                    "cd \$WORKSPACE/srcdir\n",
                    readstring(histfile))
                rm(histfile)
            end

            print_with_color(:bold, state.outs, "\n\t\t\tBuild complete\n\n")
            print(state.outs, "Your build script was:\n\n\t")
            print(state.outs, replace(history, "\n", "\n\t"))

            print_with_color(:bold, state.outs, "\n\t\t\tAnalyzing...\n\n")

            audit(prefix; io=state.outs,
                platform=Linux(:x86_64), verbose=true, autofix=false)

            println(state.outs)
            print_with_color(:bold, state.outs, "\t\t\t\# Step 4: Select build products\n\n")


            # Collect all executable/library files
            files = collapse_symlinks(collect_files(prefix))

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
            state.file_kinds = map(files) do f
                h = readmeta(f)
                isexecutable(h) ? :executable :
                islibrary(h) ? :library : :other
            end
            
            terminal = Base.Terminals.TTYTerminal("xterm", state.ins, state.outs, state.outs)

            if length(files) == 0
                # TODO: Make this a regular error path
                print_with_color(:red, state.outs, "ERROR: ")
                println(state.outs, "The build has produced no binary artifacts.")
                println(state.outs, " "^7, "This is generally because an error occured during the build")
                println(state.outs, " "^7, "or because you forgot to `make install` or equivalent.")
                println(state.outs)
                
                choice = request(terminal, "How would you like to proceed?",
                    RadioMenu([
                        "Return to build enviornment",
                        "Retry with a clean build enviornment",
                        "Edit the script"
                    ]))
                println()
                
                if choice == 1
                    continue
                elseif choice == 2
                    state.step = :step3
                    return
                elseif choice == 3
                    error("Not implemented yet")
                end
                
                return
            elseif length(files) == 1
                println(state.outs, "The build has produced only one build artifact:\n")
                println(state.outs, "\t$(state.files[1])")
            else
                println(state.outs, "The build has produced several libraries and executables.")
                println(state.outs, "Please select which of these you want to consider `products`.")
                println(state.outs, "These are generally those artifacts you will load or use from julia.")
                selected = collect(request(
                    terminal,
                    "",
                    MultiSelectMenu(state.files)))
                state.file_kinds = map(x->state.file_kinds[x], selected)
                state.files = map(x->state.files[x], selected)
            end
            
            state.history = history
            
            # Advance to next step
            state.step = :step5a

            println(state.outs)
            return
        end
    end
end

function step5a(state)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 5: Generalize the build script\n\n")

    println(state.outs, "You have successfully built for Linux x86_64 (yay!).")
    println(state.outs, "We will now attempt to use the same script to build for other architectures.")
    println(state.outs, "This will likely fail, but the failure mode will help us understand why.")
    println(state.outs, )
    print(state.outs, "Your next build target will be ")
    print_with_color(:bold, state.outs, "Win64")
    println(state.outs, ". This will help iron out any issues")
    println(state.outs, "with the cross compiler.")
    println(state.outs, )
    println(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    print_with_color(:bold, state.ins, "\t\t\t\# Attempting to build for Win64\n\n")

    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        prefix, ur = setup_workspace(build_path, state.source_files, Windows(:x86_64))

        run(ur, `/bin/bash -c $(state.history)`, joinpath(build_path,"out.log"); verbose=true, tee_stream=state.outs)

        print_with_color(:bold, state.outs, "\n\t\t\tBuild complete. Analyzing...\n\n")

        audit(prefix; io=state.outs,
            platform=Windows(:x86_64), verbose=true, autofix=false)

        match_files(prefix, Windows(:x86_64), state.files)
    end

    println(state.outs, "")
    println(state.outs, "You have successfully built for Win64. Congratulations!")
    println(state.outs)
end

function step5b(state)
    print(state.outs, "Your next build target will be Linux ")
    print_with_color(:bold, state.outs, "AArch64")
    println(state.outs, ". This should uncover issues related")
    println(state.outs, "to architecture differences.")
    println(state.outs)
    println(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    print_with_color(:bold, state.outs, "\t\t\t\# Attempting to build for Linux AArch64\n\n")

    build_path = tempname()
    mkpath(build_path)
    cd(build_path) do
        prefix, ur = setup_workspace(build_path, state.source_files, Linux(:aarch64))

        run(ur, `/bin/bash -c $(state.history)`, joinpath(build_path,"out.log"); verbose=true, tee_stream=state.outs)

        print_with_color(:bold, state.outs, "\n\t\t\tBuild complete. Analyzing...\n\n")

        audit(prefix; io=state.outs,
            platform=Linux(:aarch64), verbose=true, autofix=false)

        match_files(prefix, Linux(:aarch64), state.files)
    end

    println(state.outs, "")
    println(state.outs, "You have successfully built for Linux AArch64. Congratulations!")
    println(state.outs)
end

function step5c(state)
    println(state.outs, "We will now attempt to build all remaining architectures.")
    println(state.outs, "Note that these builds are not verbose.")
    println(state.outs, "This will probably take a while.")
    println(state.outs)
    println(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    for platform in filter(x->!(x in (Linux(:x86_64), Linux(:aarch64), Windows(:x86_64))),
            state.platforms)
        print(state.outs, "Building $platform ")
        build_path = tempname()
        mkpath(build_path)
        cd(build_path) do
            prefix, ur = setup_workspace(build_path, state.source_files, platform)

            run(ur, `/bin/bash -c $(state.history)`, joinpath(build_path,"out.log"); verbose=false, tee_stream=state.outs)

            audit(prefix; io=state.outs,
                platform=platform, verbose=false, autofix=false)

            match_files(prefix, platform, state.files)
        end
        print(state.outs, "[")
        print_with_color(:green, state.outs, "✓")
        println(state.outs, "]")
    end
end

function step6(state)
    print_with_color(:bold, state.outs, "\t\t\tDone!\n\n")

    print(state.outs, "Your build script was:\n\n\t")
    print(state.outs, replace(state.history, "\n", "\n\t"))

    print_with_color(:bold, state.outs, "\t\t\t\# Step 6: Deployment\n\n")

    println(state.outs, "Pick a name for this project. This will be used for filenames, etc (e.g. `julia`):")
    print(state.outs, "> ")
    name = readline(state.ins)

    println(state.outs, "Use this as your build_tarballs.jl:")

    platforms_string = string("[\n",join(state.platforms,",\n"),"\n]\n")
    sources_string = string("[\n",join(map(zip(state.source_urls, state.source_hashes)) do x
        (src, hash) = x
        string(repr(hash)," =>\n", repr(src), ",\n")
    end,",\n"),"]")

    stuff = collect(zip(state.files, state.file_kinds))
    products_string = join(map(stuff) do x
        file, kind = x
        file = normalize_name(file)
        kind == :executable ? "\tExecutableProduct(prefix,$(repr(file)))" :
        kind == :library ? "\tLibraryProduct(prefix,$(repr(file)))" :
        "\tFileProduct(prefix,$(repr(file)))"
    end,",\n")

    println(state.outs, """

    ```
    using BinaryBuilder

    platforms = $platforms_string
    sources = $sources_string

    script = raw\"\"\"
    $(state.history)
    \"\"\"

    products = prefix -> [
    $products_string
    ]

    autobuild(pwd(), "$name", platforms, sources, script, products)
    ```
    """)

    println(state.outs, "Use this as your .travis.yml")

    println(state.outs, """

    ```
    language: julia
    os:
      - linux
    julia:
      - 0.6
    notifications:
      email: false
    git:
      depth: 99999999
    sudo: required
    services:
      - docker

    env:
      DOCKER_IMAGE: staticfloat/julia_crossbuild:x64

    # Before anything else, get the latest versions of things
    before_script:
      - docker pull \$DOCKER_IMAGE
      - julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryProvider.jl")'
      - julia -e 'Pkg.clone("https://github.com/staticfloat/ObjectFile.jl")'
      - julia -e 'Pkg.clone("https://github.com/JuliaPackaging/BinaryBuilder.jl"); Pkg.build()'

    script:
      - julia build_tarballs.jl
    ```
    """)
end

function run_wizard(state = State())
    println(state.outs,
            "Welcome to the BinaryBuilder wizard.\n"*
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
            elseif state.step == :step5a
                step5a(state)
                state.step = :step5b
            elseif state.step == :step5b
                step5b(state)
                state.step = :step5c
            elseif state.step == :step5c
                step5c(state)
                state.step = :step6
            elseif state.step == :step6
                step6(state)
                state.step = :done
            end
        end
    catch err
        bt = catch_backtrace()
        Base.showerror(STDERR, err, bt)
        println(state.outs, "\n")
        return state
    end

    println(state.outs, "\nWizard Complete. Press any key to exit...")
    read(state.ins, Char)

    state
end
