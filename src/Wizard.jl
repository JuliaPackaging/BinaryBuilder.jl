using Base.Terminals
using TerminalMenus
using ObjectFile.ELF


"""
    WizardState

Building large dependencies can take a lot of time. This state object captures
all relevant state of this function. It can be passed back to the function to
resume where we left off. This can aid debugging when code changes are
necessary.  It also holds all necessary metadata such as input/output streams.
"""
mutable struct WizardState
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
    # Filled in by step 5c
    failed_platforms::Set{Any}
end

function WizardState()
    WizardState(
        :step1,
        STDIN,
        STDOUT,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        Set{Any}()
    )
end

"""
    yn_prompt(state::WizardState, question::AbstractString, default = :y)

Perform a `[Y/n]` or `[y/N]` question loop, using `default` to choose between
the prompt styles, and looping until a proper response (e.g. `"y"`, `"yes"`,
`"n"` or `"no"`) is received.
"""
function yn_prompt(state::WizardState, question::AbstractString, default = :y)
    @assert default in (:y, :n)
    ynstr = default == :y ? "[Y/n]" : "[y/N]"
    while true
        print(state.outs, question, " ", ynstr, ": ")
        answer = lowercase(strip(readline(state.ins)))
        if isempty(answer)
            return default
        elseif answer == "y" || answer == "yes"
            return :y
        elseif answer == "n" || answer == "no"
            return :n
        else
            println(state.outs, "Unrecognized answer. Answer `y` or `n`.")
        end
    end
end

"""
    download_source(state::WizardState)

Ask the user where the source code is coming from, then download and record the
relevant parameters, returning the source `url`, the local `path` it is stored
at after download, and a `hash` identifying the version of the code. In the
case of a `git` source URL, the `hash` will be a git treeish identifying the
exact commit used to build the code, in the case of a tarball, it is the
`sha256` hash of the tarball itself.
"""
function download_source(state::WizardState)
    # First, ask the user where this is all coming from
    msg = replace(strip("""
    Please enter a URL (git repository or gzipped tarball) containing the
    source code to build:
    """), "\n", " ")
    print(state.outs, msg, "\n> ")
    url = readline(state.ins)
    println(state.outs)

    # Record the source path and the source hash
    source_path = joinpath(state.workspace, basename(url))
    local source_hash

    if endswith(url, ".git")
        # Clone the URL, record the current gitsha for the given branch
        repo = LibGit2.clone(url, source_path; isbare=true)

        msg = replace(strip("""
        You have selected a git repository. Please enter a branch, commit or
        tag to use.  Please note that for reproducability, the exact commit
        will be recorded, so updates to the remote resource will not be used
        automatically; you will have to manually update the recorded commit.
        """), "\n", " ")
        print(state.outs, msg, "\n> ")
        treeish = readline(state.ins)
        println(state.outs)

        obj = LibGit2.GitObject(repo, treeish)
        source_hash = LibGit2.hex(LibGit2.GitHash(obj))
        
        # Tell the user what we recorded the current commit as
        print(state.outs, "Recorded as ")
        print_with_color(:bold, state.outs, source_hash)
        println(state.outs)
        close(repo)
    else
        # Download the source tarball
        source_path = joinpath(state.workspace, basename(url))
    
        if isfile(source_path)
            name, ext = splitext(basename(source_path))
            n = 1
            while isfile(joinpath(state.workspace, "$(name)_$n$ext"))
                n += 1
            end
            source_path = joinpath(state.workspace, "$(name)_$n$ext")
        end
        
        download_cmd = gen_download_cmd(url, source_path)
        oc = OutputCollector(download_cmd; verbose=true, tee_stream=state.outs)
        try
            if !wait(oc)
                error()
            end
        catch
            error("Could not download $(url) to $(state.workspace)")
        end

        # Save the source hash
        open(source_path) do file
            source_hash = bytes2hex(BinaryProvider.sha256(file))
        end
    end

    # Spit back the url, local path and source hash
    return url, source_path, source_hash
end

"""
    normalize_name(file::AbstractString)

Given a filename, normalize it, stripping out extensions.  E.g. the file path
`"foo/libfoo.tar.gz"` would get mapped to `"libfoo"`.
"""
function normalize_name(file::AbstractString)
    file = basename(file)
    idx = findfirst(file, '.')
    if idx != 0
        return file[1:prevind(file, idx)]
    end
    return file
end

"""
    match_files(state::WizardState, prefix::Prefix,
                platform::Platform, files::Vector; silent::Bool = false)

Inspects all binary files within a prefix, matching them with a given list of
`files`, complaining if there are any files that are not properly matched and
returning the set of normalized names that were not matched, or an empty set if
all names were properly matched.
"""
function match_files(state::WizardState, prefix::Prefix,
                     platform::Platform, files::Vector; silent::Bool = false)
    # Collect all executable/library files
    prefix_files = collapse_symlinks(collect_files(prefix))
    # Check if we can load them as an object file
    prefix_files = filter(prefix_files) do f
        try
            h = readmeta(f)
            if !is_for_platform(h, platform)
                if !silent
                    warn(state.outs, "Skipping binary `$f` with incorrect platform")
                end
                return false
            end
            return true
        catch
            return false
        end
    end

    norm_prefix_files = Set(map(normalize_name, prefix_files))
    norm_files = Set(map(normalize_name, files))
    d = setdiff(norm_files, norm_prefix_files)
    if !isempty(d)
        if !silent
            warn(state.outs, "Could not find correspondences for $(join(d, ' '))")
        end
    end
    return d
end

"""
    edit_script(state::WizardState, script::AbstractString)

For consistency (and security), use the sandbox for editing a script, launching
`vi` within an interactive session to edit a buildscript.
"""
function edit_script(state::WizardState, script::AbstractString)
    # Create a temporary directory to hold the script inside of
    temp_prefix() do prefix
        # Write the script out to a file
        path = joinpath(prefix, "script")
        open(path, "w") do f
            write(f, script)
        end
    
        # Launch a sandboxed vim editor
        ur = UserNSRunner(
            workspace = prefix.path,
            cwd = "/workspace/",
            platform = Linux(:x86_64))
        run_interactive(ur, `/usr/bin/vi /workspace/script`,
                        state.ins, state.outs, state.outs)
    
        # Once the user is finished, read the script back in
        script = readstring(path)
    end
    return script
end


"""
    step1(state::WizardState)

It all starts with a single step, the unabashed ambition to leave your current
stability and engage with the universe on a quest to create something new, and
beautiful and unforseen.  It all ends with compiler errors.

This step selets the relevant platform(s) for the built binaries.
"""
function step1(state::WizardState)
    # Select a platform
    msg = "\t\t\t\# Step 1: Select your platforms\n\n"
    print_with_color(:bold, state.outs, msg)
    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    platform_select = request(terminal,
        "Make a platform selection",
        RadioMenu([
            "All supported architectures",
            "Specific operating system",
            "Specific architecture",
            "Custom",
        ])
    )
    println(state.outs)

    # Set `state.platforms` accordingly
    if platform_select == 1
        state.platforms = supported_platforms()
    elseif platform_select == 2
        oses = sort(unique(map(typeof, supported_platforms())), by = repr)
        result = request(terminal,
            "Select operating systems",
            MultiSelectMenu(map(repr, oses))
        )
        result = map(x->oses[x], result)
        state.platforms = collect(filter(x->typeof(x) in result, supported_platforms()))
    elseif platform_select == 3
        arches = sort(unique(map(arch, supported_platforms())), by = repr)
        result = request(terminal,
            "Select architectures",
            MultiSelectMenu(map(repr, arches))
        )
        result = map(x->arches[x], result)
        state.platforms = collect(filter(x->arch(x) in result, supported_platforms()))
    elseif platform_select == 4
        platfs = supported_platforms()
        result = request(terminal,
            "Select platforms",
            MultiSelectMenu(map(repr, platfs))
        )
        state.platforms = collect(map(x->platfs[x], result))
    else
        error("Somehow platform_select was not a valid choice!")
    end

    println(state.outs)
end

"""
    step2(state::WizardState)

This step obtains the source code to be built.
"""
function step2(state::WizardState)
    msg = "\t\t\t\# Step 2: Obtain the source code\n\n"
    print_with_color(:bold, state.outs, msg)

    # Create the workspace that we'll stash everything within
    state.workspace = tempname()
    mkpath(state.workspace)

    # These are the metadata we need to know about all the sources we'll be
    # building over the course of this journey we're on together.
    state.source_urls = String[]
    state.source_files = String[]
    state.source_hashes = String[]

    while true
        url, file, hash = download_source(state)
        push!(state.source_urls, url)
        push!(state.source_files, file)
        push!(state.source_hashes, hash)
        println(state.outs)

        q = "Would you like to download additional sources? "
        if yn_prompt(state, q, :n) != :y
            break
        end
    end
    println(state.outs)
end

"""
    print_autoconf_hint(state::WizardState)

Print a hint for projets that use autoconf to have a good `./configure` line.
"""
function print_autoconf_hint(state::WizardState)
    print(state.outs, "     The recommended options for GNU Autoconf are")
    print(state.outs, " `")
    print_with_color(:bold, state.outs, "./configure --prefix=/ --host=\$target")
    println(state.outs, "`")
    println(state.outs, "    followed by `make` and `make install`. Since the DESTDIR environment")
    println(state.outs, "    variable is set already, this will automatically perform the installation")
    println(state.outs, "    into the correct directory.\n")
end

"""
    provide_hints(state::WizardState, path::AbstractString)

Given an unpacked source directory, provide hints on how a user might go about
building the binary bounty they so richly desire.
"""
function provide_hints(state::WizardState, path::AbstractString)
    files = readdir(path)
    println(state.outs,
        "You have the following contents in your working directory:")
    println(state.outs, join(map(x->string("  - ", x),files),'\n'))
    printed = false
    function start_hints()
        printed || print_with_color(:yellow, state.outs, "Hints:\n")
        printed = true
    end
    for (root, dirs, files) in walkdir(path)
        for file in files
            file_path = joinpath(root, file)
            contents = readstring(file_path)
            if file == "configure" && contains(contents, "Generated by GNU Autoconf")
                start_hints()
                println(state.outs, "  - ", replace(file_path, "$path/", ""), "\n")
                println(state.outs, "    This file is a configure file generated by GNU Autoconf. ")
                print_autoconf_hint(state)
            elseif file == "configure.in" || file == "configure.ac"
                println(state.outs, "  - ", replace(file_path, "$path/", ""), "\n")
                println(state.outs, "    This file is likely input to GNU Autoconf. ")
                print_autoconf_hint(state)
            end
        end
    end
    println(state.outs)
end

"""
    setup_workspace(build_path::AbstractString, src_paths::Vector,
                    src_hashes::Vector, platform::Platform,
                    extra_env::Dict{String, String};
                    verbose::Bool = false, tee_stream::IO = STDOUT)

Sets up a workspace within `build_path`, creating the directory structure
needed by further steps, unpacking the source within `build_path`, and defining
the environment variables that will be defined within the sandbox environment.

This method returns the `Prefix` to install things into, the `srcdir` in which
the given source has been unpacked to, and the `UserNSRunner` that can be used
to launch commands within this workspace.
"""
function setup_workspace(build_path::AbstractString, src_paths::Vector,
                         src_hashes::Vector, platform::Platform,
                         extra_env::Dict{String, String} =
                             Dict{String, String}();
                         verbose::Bool = false, tee_stream::IO = STDOUT)
    # Upper dir for the root overlay
    mkdir(joinpath(build_path, "overlay_root"))
    # Working directory for the root overlay
    mkdir(joinpath(build_path, "overlay_workdir"))
    # Workspace root
    mkdir(joinpath(build_path, "workspace"))
    
    # Use a random nonce to make detection of paths in embedded binary easier
    nonce = randstring()
    mkdir(joinpath(build_path, "workspace", nonce))

    # We now set up two directories, one as a source dir, one as a dest dir
    srcdir = joinpath(build_path, "workspace", nonce, "srcdir")
    destdir = joinpath(build_path, "workspace", nonce, "destdir")
    mkdir(srcdir); mkdir(destdir)
    
    # Create a runner to work inside this workspace with the nonce built-in
    ur = UserNSRunner(build_path,
        cwd = "/workspace/$nonce/srcdir",
        platform = platform,
        extra_env = merge(extra_env,
            Dict(
                "DESTDIR" => "/workspace/$nonce/destdir",
                "WORKSPACE" => "/workspace/$nonce",
            )
        )
    )

    # Unpack the sources into the srcdir
    cmds = Any[""]

    # For each source path, unpack it
    for (src_path, src_hash) in zip(src_paths, src_hashes)
        if isdir(src_path)
            # Chop off the `.git` at the end of the src_path
            repo_dir = joinpath(srcdir, basename(src_path)[1:end-4])
            LibGit2.with(LibGit2.clone(src_path, repo_dir)) do repo
                LibGit2.checkout!(repo, src_hash)
            end
        else
            # For consistency, we use the tar inside the sandbox to unpack
            cp(src_path, joinpath(srcdir, basename(src_path)))
            if endswith(src_path, ".tar") || endswith(src_path, ".tar.gz") ||
               endswith(src_path, ".tar.bz") || endswith(src_path, ".tar.xz")
                push!(cmds, "tar xof $(basename(src_path))")
            elseif endswith(src_path, ".zip")
                push!(cmds, "unzip -q $(basename(src_path))")
            end
            push!(cmds, "rm $(basename(src_path))")
        end
    end

    # Run the cmds defined above
    run(ur, `/bin/bash -c $(join(cmds, '\n'))`, ""; verbose=verbose, tee_stream=tee_stream)

    # Return the prefix and the runner
    return Prefix(destdir), srcdir, ur
end

"""
    step4(state::WizardState, ur::UserNSRunner,
          build_path::AbstractString, prefix::Prefix)

The fourth step selects build products after the build is done for Linux x86_64
"""
function step4(state::WizardState, ur::UserNSRunner,
               build_path::AbstractString, prefix::Prefix)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 4: Select build products\n\n")

    # Collect all executable/library files
    files = collapse_symlinks(collect_files(prefix))

    # Check if we can load them as an object file
    files = filter(files) do f
        try
            h = readmeta(f)
            is_for_platform(h, Linux(:x86_64)) || return false
            return true
        catch
            return false
        end
    end

    # Strip out the prefix from filenames
    state.files = map(file->replace(file, prefix.path, ""), files)
    state.file_kinds = map(files) do f
        h = readmeta(f)
        isexecutable(h) ? :executable :
        islibrary(h) ? :library : :other
    end
    
    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

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
        println(state.outs)
        
        if choice == 1
            return step3_interactive(state, prefix, ur, build_path)
        elseif choice == 2
            state.step = :step3
            return
        elseif choice == 3
            state.history = edit_script(state, state.history)
            state.step = :step3_retry
            return
        end
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
    
    # Advance to next step
    state.step = :step5a
    
    println(state.outs)
end

"""
    step3_audit(state::WizardState, prefix::Prefix)

Audit the `prefix`.
"""
function step3_audit(state::WizardState, prefix::Prefix)
    print_with_color(:bold, state.outs, "\n\t\t\tAnalyzing...\n\n")

    audit(prefix; io=state.outs,
        platform=Linux(:x86_64), verbose=true, autofix=false)

    println(state.outs)
end

"""
    step3_interactive(state::WizardState, prefix::Prefix,
                      ur::UserNSRunner, build_path::AbstractString)

Runs the interactive shell for building, then captures bash history to save
reproducible steps for building this source.
"""
function step3_interactive(state::WizardState, prefix::Prefix,
                           ur::UserNSRunner, build_path::AbstractString)
    histfile = joinpath(build_path, "workspace", ".bash_history")
    runshell(ur, state.ins, state.outs, state.outs)

    # This is an extremely simplistic way to capture the history,
    # but ok for now. Obviously doesn't include any interactive
    # programs, etc.
    if isfile(histfile)
        state.history = string(state.history,
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
    print(state.outs, replace(state.history, "\n", "\n\t"))
    println(state.outs)

    if yn_prompt(state, "Would you like to edit this script now?", :n) == :y
        state.history = edit_script(state, state.history)
        
        println(state.outs)
        msg = strip("""
        We will now rebuild with your new script to make sure it still works.
        """)
        println(state.outs, msg)
        println(state.outs)
        
        state.step = :step3_retry
    else
        step3_audit(state, prefix)

        return step4(state, ur, build_path, prefix)
    end
end

"""
    step3_retry(state::WizardState)

Rebuilds the initial Linux x86_64 build after things like editing the script
file manually, etc...
"""
function step3_retry(state::WizardState)
    platform = Linux(:x86_64)
    
    msg = "\t\t\t\# Attempting to build for $platform\n\n"
    print_with_color(:bold, state.ins, msg)

    build_path = tempname()
    mkpath(build_path)
    local ok = true
    cd(build_path) do
        prefix, srcdir, ur = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes,
            platform;
            verbose=true,
            tee_stream=state.outs
        )

        run(ur,
            `/bin/bash -c $(state.history)`,
            joinpath(build_path,"out.log");
            verbose=true,
            tee_stream=state.outs
        )

        step3_audit(state, prefix)
        
        return step4(state, ur, build_path, prefix)
    end
end

"""
    step34(state::WizardState)

Starts initial build for Linux x86_64, which is our initial test target
platform.  Sources that build properly for this platform continue on to attempt
builds for more complex platforms.
"""
function step34(state::WizardState)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 3: Build for Linux x86_64\n\n")

    msg = strip("""
    You will now be dropped into the cross-compilation environment.
    Please compile the library. Your initial compilation target is Linux x86_64.
    The \$DESTDIR environment variable contains the target directory.
    Many build systems will respect this variable automatically.
    Once you are done, exit by typing `exit` or `^D`
    """)
    println(state.outs, msg)
    println(state.outs)

    build_path = tempname()
    mkpath(build_path)
    state.history = ""
    cd(build_path) do
        histfile = joinpath(build_path, "workspace", ".bash_history")
        prefix, ur = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes,
            Linux(:x86_64),
            Dict("HISTFILE"=>"/workspace/.bash_history");
            verbose=true,
            tee_stream=state.outs
        )
        provide_hints(state, joinpath(prefix.path, "..", "srcdir"))

        return step3_interactive(state, prefix, ur, build_path)
    end
end

function step5_internal(state::WizardState, platform::Platform, message)
    print(state.outs, "Your next build target will be ")
    print_with_color(:bold, state.outs, platform)
    println(state.outs, message)
    println(state.outs)
    println(state.outs, "Press any key to continue...")
    read(state.ins, Char)
    println(state.outs)

    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)

    print_with_color(:bold, state.ins, "\t\t\t\# Attempting to build for $platform\n\n")

    build_path = tempname()
    mkpath(build_path)
    local ok = true
    cd(build_path) do
        prefix, srcdir, ur = setup_workspace(
            build_path,
            state.source_files,
            state.source_hashes,
            platform;
            verbose=true,
            tee_stream=state.outs
        )

        run(ur,
            `/bin/bash -c $(state.history)`,
            joinpath(build_path,"out.log");
            verbose=true,
            tee_stream=state.outs
        )

        msg = "\n\t\t\tBuild complete. Analyzing...\n\n"
        print_with_color(:bold, state.outs, msg)

        audit(prefix; io=state.outs,
            platform=platform, verbose=true, autofix=false)

        ok = isempty(match_files(state, prefix, platform, state.files))
        if !ok
            println(state.outs)
            print_with_color(:red, state.outs, "ERROR: ")
            msg = "Some build products could not be found (see above)."
            println(state.outs, msg)
            println(state.outs)
            
            # N.B.: This is a Star Trek reference (TNG Season 1, Episode 25,
            # 25:00).
            choice = request(terminal,
                "Please specify how you would like to proceed, sir.",
                RadioMenu([
                    "Drop into build environment",
                    "Open a clean session for this platform",
                    "Disable this platform",
                    "Edit build script",
                ])
            )
                
            if choice == 1
                runshell(ur, state.ins, state.outs, state.outs)
                # TODO: Append this as platform_only to the build script
            elseif choice == 2
                error("Not implemented yet")
            elseif choice == 3
                filter!(p->p != platform, state.platforms)
                ok = true
            elseif choice == 4
                state.history = edit_script(state, state.history)
                # Well go around again after this
            end
        else
            println(state.outs, "")
            msg = "You have successfully built for $platform. Congratulations!"
            println(state.outs, msg)
        end

        println(state.outs)
    end
    return ok
end

function step5a(state::WizardState)
    print_with_color(:bold, state.outs, "\t\t\t\# Step 5: Generalize the build script\n\n")

    msg = strip("""
    You have successfully built for Linux x86_64 (yay!).
    We will now attempt to use the same script to build for other architectures.
    This will likely fail, but the failure mode will help us understand why.
    """)
    println(state.outs, msg)

    msg = ".\n This will help iron out any issues\nwith the cross compiler"
    if step5_internal(state, Windows(:x86_64), msg)
        state.step = :step5b
        # Otherwise go around again
    end
end

function step5b(state::WizardState)
    if step5_internal(state, Linux(:aarch64),
    ".\n This should uncover issues related\nto architecture differences.")
        state.step = :step5c
    end
end

function step5c(state::WizardState)
    msg = strip("""
    We will now attempt to build all remaining architectures.
    Note that these builds are not verbose.
    This will probably take a while.

    Press any key to continue...
    """)
    println(state.outs, msg)
    read(state.ins, Char)
    println(state.outs)

    pred = x -> !(x in (Linux(:x86_64), Linux(:aarch64), Windows(:x86_64)))
    for platform in filter(pred, state.platforms)
        print(state.outs, "Building $platform ")
        build_path = tempname()
        mkpath(build_path)
        local ok = true
        cd(build_path) do
            prefix, srcdir, ur = setup_workspace(
                build_path,
                state.source_files,
                state.source_hashes,
                platform;
                verbose=false,
                tee_stream=state.outs
            )

            run(ur,
                `/bin/bash -c $(state.history)`,
                joinpath(build_path,"out.log");
                verbose=false,
                tee_stream=state.outs
            )

            audit(prefix;
                io=state.outs,
                platform=platform,
                verbose=false,
                silent=true,
                autofix=false
            )

            ok = isempty(match_files(
                state,
                prefix,
                platform,
                state.files;
                silent = true
            ))
        end
        print(state.outs, "[")
        if ok
            print_with_color(:green, state.outs, "✓")
        else
            print_with_color(:red, state.outs, "✗")
            push!(state.failed_platforms, platform)
        end
        println(state.outs, "]")
    end
    
    println(state.outs)
end

function step6(state::WizardState)
    if isempty(state.failed_platforms)
        state.step = :step7
        return
    end
    
    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    
    msg = "\t\t\t\# Step 6: Revisit failed platforms\n\n"
    print_with_color(:bold, state.outs, msg)
    
    println(state.outs, "Several platforms failed to build:")
    for plat in state.failed_platforms
        println(state.outs, " - ", plat)
    end
    
    println(state.outs)
    
    choice = request(terminal,
        "What would you like to do?",
        RadioMenu([
            "Disable these platforms",
            "Revisit manually",
            "Edit script and retry all",
        ])
    )

    println(state.outs)
    
    if choice == 1
        filter!(p->!(p in state.failed_platforms), state.platforms)
        state.step = :step7
    elseif choice == 2
        plats = collect(state.failed_platforms)
        if length(plats) > 1
            choice = request(terminal,
                "Which platform would you like to revisit?",
                RadioMenu(map(repr, plats)))
            println(state.outs)
        else
            choice = 1
        end
        if step5_internal(state, plats[choice], ". ")
            delete!(state.failed_platforms, plats[choice])
        end
        # Will wrap back around to step 6
    elseif choice == 3
        state.history = edit_script(state, state.history)
        # Will wrap back around to step 6
    end
end

function step7(state::WizardState)
    print_with_color(:bold, state.outs, "\t\t\tDone!\n\n")

    print(state.outs, "Your build script was:\n\n\t")
    print(state.outs, replace(state.history, "\n", "\n\t"))

    print_with_color(:bold, state.outs, "\t\t\t\# Step 7: Deployment\n\n")

    msg = strip("""
    Pick a name for this project.  This will be used for filenames:
    """)
    print(state.outs, msg, "\n> ")
    name = readline(state.ins)
    println(state.outs, "Use this as your build_tarballs.jl:")

    platforms_string = string("[\n",join(state.platforms,",\n"),"\n]\n")
    urlhashes = zip(state.source_urls, state.source_hashes)
    sources_string = string("[\n",join(map(urlhashes) do x
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

function print_wizard_logo(outs)
    logo = raw"""

            o      `.
           o*o      \'-_                 00000000: 01111111 $.
             \\      \;"".     ,;.--*    00000001: 01000101 $E
              \\     ,\''--.--'/         00000003: 01001100 $L
              :=\--<' `""  _   |         00000003: 01000110 $F
              ||\\     `" / ''--         00000004: 00000010  .
              `/_\\,-|    |              00000005: 00000001  .
                  \\/     L
                   \\ ,'   \
                 _/ L'   `  \
                /  /    /   /          Julia Binzard
               /  /    |    \          JuliaPackaging/BinaryBuilder.jl
              "_''--_-''---__=;

    """

    blue    = "\033[34m"
    red     = "\033[31m"
    green   = "\033[32m"
    magenta = "\033[35m"
    normal  = "\033[0m\033[0m"

    logo = replace(logo, " o ", " $(green)o$(normal) ")
    logo = replace(logo, "o*o", "$(red)o$(blue)*$(magenta)o$(normal)")

    logo = replace(logo, ".--*", "$(red).$(green)-$(magenta)-$(blue)*$(normal)")

    logo = replace(logo, "\$.", " $(blue).$(normal)")
    logo = replace(logo, "\$E", " $(red)E$(normal)")
    logo = replace(logo, "\$L", " $(green)L$(normal)")
    logo = replace(logo, "\$F", " $(magenta)F$(normal)")

    print(outs, logo)
end

function run_wizard(state::WizardState = WizardState())
    print_wizard_logo(state.outs)
    
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
            elseif state.step == :step3_retry
                step3_retry(state)
            elseif state.step == :step5a
                step5a(state)
            elseif state.step == :step5b
                step5b(state)
            elseif state.step == :step5c
                step5c(state)
                state.step = :step6
            elseif state.step == :step6
                step6(state)
            elseif state.step == :step7
                step7(state)
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
