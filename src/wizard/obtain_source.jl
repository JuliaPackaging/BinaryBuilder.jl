using ProgressMeter


"""
Canonicalize a GitHub repository URL
"""
function canonicalize_source_url(url)
    repo_regex = r"(https:\/\/)?github.com\/([^\/]+)\/([^\/]+)\/?$"

    m = match(repo_regex, url)
    if m !== nothing
        _, user, repo = m.captures
        if !endswith(repo, ".git")
            return "https://github.com/$user/$repo.git"
        end
    end
    url
end

struct GitTransferProgress
    total_objects::Cuint
    indexed_objects::Cuint
    received_objects::Cuint
    local_objects::Cuint
    total_deltas::Cuint
    indexed_deltas::Cuint
    received_bytes::Csize_t
end

function transfer_progress(progress::Ptr{GitTransferProgress}, p::Any)
    progress = unsafe_load(progress)
    p.n = progress.total_objects
    if progress.total_deltas != 0
        p.desc = "Resolving Deltas: "
        p.n = progress.total_deltas
        update!(p, Int(max(1, progress.indexed_deltas)))
    else
        update!(p, Int(max(1, progress.received_objects)))
    end
    return Cint(0)
end

macro compat_gc_preserve(args...)
    if VERSION >= v"0.7-"
        esc(Expr(:macrocall, Expr(:., :GC, QuoteNode(Symbol("@preserve"))), args...))
    else
        esc(args[end])
    end
end

function clone(url, source_path)
    p = Progress(0, 1, "Cloning: ")
    @compat_gc_preserve p begin
        @static if VERSION >= v"0.7-"
            callbacks = LibGit2.RemoteCallbacks(transfer_progress=@cfunction(transfer_progress, Cint, (Ptr{GitTransferProgress}, Any)),
                payload = p)
        else
            callbacks = LibGit2.RemoteCallbacks(transfer_progress=cfunction(transfer_progress, Cint, Tuple{Ptr{GitTransferProgress}, Any}),
                payload = pointer_from_objref(p))
        end
        fetch_opts = LibGit2.FetchOptions(callbacks = callbacks)
        clone_opts = LibGit2.CloneOptions(fetch_opts=fetch_opts, bare = Cint(true))
        return LibGit2.clone(url, source_path, clone_opts)
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
    Please enter a URL (git repository or compressed archive) containing the
    source code to build:
    """), "\n" => " ")
    print(state.outs, msg, "\n> ")
    entered_url = readline(state.ins)
    println(state.outs)

    url = canonicalize_source_url(entered_url)
    if url != entered_url
        print(state.outs, "The entered URL has been canonicalized to\n")
        printstyled(state.outs, url, bold=true)
        println(state.outs)
        println(state.outs)
    end

    # Record the source path and the source hash
    source_path = joinpath(state.workspace, basename(url))
    local source_hash

    if endswith(url, ".git")
        # Clone the URL, record the current gitsha for the given branch
        repo = clone(url, source_path)

        msg = "You have selected a git repository. Please enter a branch, commit or tag to use.\n" *
        "Please note that for reproducability, the exact commit will be recorded, \n" *
        "so updates to the remote resource will not be used automatically; \n" *
        "you will have to manually update the recorded commit."
        print(state.outs, msg, "\n> ")
        treeish = readline(state.ins)
        println(state.outs)

        obj = try
            LibGit2.GitObject(repo, treeish)
        catch
            LibGit2.GitObject(repo, "origin/$treeish")
        end
        source_hash = LibGit2.hex(LibGit2.GitHash(obj))

        # Tell the user what we recorded the current commit as
        print(state.outs, "Recorded as ")
        printstyled(state.outs, source_hash, bold=true)
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
    printstyled(state.outs, msg, bold=true)
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
Canonicalize URL to a file within a GitHub repo
"""
function canonicalize_file_url(url)
    blob_regex = r"(https:\/\/)?github.com\/([^\/]+)\/([^\/]+)\/blob\/([^\/]+)\/(.+)"
    m = match(blob_regex, url)
    if m !== nothing
        _, user, repo, ref, filepath = m.captures
        if length(ref) != 40 || !all(c->isnumber(c) || c in 'a':'f' || c in 'A':'F', ref)
            # Ask github to resolve this ref for us
            ref = get(GitHub.reference(GitHub.Repo("$user/$repo"), "heads/$ref").object)["sha"]
        end
        return "https://raw.githubusercontent.com/$user/$repo/$ref/$(filepath)"
    end
    url
end

function obtain_binary_deps(state::WizardState)
    msg = "\t\t\t# Step 2b: Obtain binary dependencies (if any)\n\n"
    printstyled(state.outs, msg, bold=true)

    q = "Do you require any (binary) dependencies? "
    if yn_prompt(state, q, :n) == :y
        empty!(state.dependencies)
        terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
        while true
            bindep_select = request(terminal,
                "How would you like to specify this dependency?",
                RadioMenu([
                    "Provide remote build.jl file",
                    "Paste in a build.jl file",
                    "Never mind",
                ])
            )
            println(state.outs)

            if bindep_select == 1
                println(state.outs, "Enter the URL to use: ")
                print(state.outs, "> ")
                url = readline(state.ins)
                println(state.outs)
                canon_url = canonicalize_file_url(url)
                if url != canon_url
                    print(state.outs, "The entered URL has been canonicalized to\n")
                    printstyled(state.outs, canon_url, bold=true)
                    println(state.outs)
                    println(state.outs)
                end
                push!(state.dependencies, RemoteBuildDependency(canon_url,
                    String(HTTP.get(canon_url).body)))
            elseif bindep_select == 2
                println(state.outs, "Please provide the build.jl file. Press ^D when you're done")
                script = String(read(state.ins))
                Base.reseteof(terminal)
                push!(state.dependencies, InlineBuildDependency(script))
            elseif bindep_select == 3
                break
            end

            q = "Would you like to provide additional dependencies? "
            if yn_prompt(state, q, :n) != :y
                println(state.outs)
                break
            end
        end
    end
end

function obtain_source(state::WizardState)
    msg = "\t\t\t# Step 2a: Obtain the source code\n\n"
    printstyled(state.outs, msg, bold=true)

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
    step2(state::WizardState)

This step obtains the source code to be built and required binary dependencies.
"""
function step2(state::WizardState)
    obtain_source(state)
    obtain_binary_deps(state)
end
