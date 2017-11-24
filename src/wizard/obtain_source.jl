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
    step1(state::WizardState)

It all starts with a single step, the unabashed ambition to leave your current
stability and engage with the universe on a quest to create something new, and
beautiful and unforseen.  It all ends with compiler errors.

This step selets the relevant platform(s) for the built binaries.
"""
function step1(state::WizardState)
    # Select a platform
    msg = "\t\t\t# Step 1: Select your platforms\n\n"
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
    msg = "\t\t\t# Step 2: Obtain the source code\n\n"
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
