using BinaryBuilderBase: available_gcc_builds, available_llvm_builds, enable_apple_file, macos_sdk_already_installed, accept_apple_sdk
using ProgressMeter
import Downloads
const update! = ProgressMeter.update!

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

"""
Canonicalize URL to a file within a GitHub repo
"""
function canonicalize_file_url(url)
    blob_regex = r"(https:\/\/)?github.com\/([^\/]+)\/([^\/]+)\/blob\/([^\/]+)\/(.+)"
    m = match(blob_regex, url)
    if m !== nothing
        _, user, repo, ref, filepath = m.captures
        if length(ref) != 40 || !all(c->isnumeric(c) || c in 'a':'f' || c in 'A':'F', ref)
            # Ask github to resolve this ref for us
            ref = GitHub.reference(GitHub.Repo("$user/$repo"), "heads/$ref").object["sha"]
        end
        return "https://raw.githubusercontent.com/$user/$repo/$ref/$(filepath)"
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

"""
    clone(url::String, source_path::String)

Clone a git repository hosted at `url` into `source_path`, with a progress bar
displayed to stdout.
"""
function clone(url::String, source_path::String)
    # Clone with a progress bar
    p = Progress(0, 1, "Cloning: ")
    GC.@preserve p begin
        callbacks = LibGit2.RemoteCallbacks(
            transfer_progress=@cfunction(
                transfer_progress,
                Cint,
                (Ptr{GitTransferProgress}, Any)
            ),
            payload = p
        )
        fetch_opts = LibGit2.FetchOptions(callbacks=callbacks)
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
    entered_url = nothing
    while entered_url === nothing #&& !eof(state.ins)
        # First, ask the user where this is all coming from
        msg = replace(strip("""
        Please enter a URL (git repository or compressed archive) containing the
        source code to build or `N` to stop:
        """), "\n" => " ")
        new_entered_url = nonempty_line_prompt("URL", msg; ins=state.ins, outs=state.outs)
        if new_entered_url == "N" 
            return new_entered_url, SetupSource(string(new_entered_url), "", "", "")
        end
        # Early-exit for invalid URLs, using HTTP.URIs.parse_uri() to ensure
        # it is a valid URL
        try
            HTTP.URIs.parse_uri(new_entered_url; strict=true)
            entered_url = new_entered_url
        catch e
            printstyled(state.outs, e.msg, color=:red, bold=true)
            println(state.outs)
            println(state.outs)
            continue
        end
    end
    # Did the user exit out with ^D or something else go horribly wrong?
    if entered_url === nothing
        error("Could not obtain source URL")
    end

    url = string(canonicalize_source_url(entered_url))
    if url != entered_url
        print(state.outs, "The entered URL has been canonicalized to\n")
        printstyled(state.outs, url, bold=true)
        println(state.outs)
        println(state.outs)
    end

    # Record the source path and the source hash
    source_path = joinpath(state.workspace, basename(url))
    local source_hash

    if endswith(url, ".git") || startswith(url, "git://")
        # Clone the URL, record the current gitsha for the given branch
        repo = clone(url, source_path)

        msg = "You have selected a git repository. Please enter a branch, commit or tag to use.\n" *
        "Please note that for reproducibility, the exact commit will be recorded, \n" *
        "so updates to the remote resource will not be used automatically; \n" *
        "you will have to manually update the recorded commit."
        #print(state.outs, msg, "\n> ")
        treeish = nonempty_line_prompt("git reference", msg; ins=state.ins, outs=state.outs)

        obj = try
            LibGit2.GitObject(repo, treeish)
        catch
            LibGit2.GitObject(repo, "origin/$treeish")
        end
        source_hash = LibGit2.string(LibGit2.GitHash(obj))

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

        Downloads.download(url, source_path)

        # Save the source hash
        open(source_path) do file
            source_hash = bytes2hex(sha256(file))
        end
    end

    # Spit back the url, local path and source hash
    return url, SetupSource(url, source_path, source_hash, "")
end

"""
    step1(state::WizardState)

It all starts with a single step, the unabashed ambition to leave your current
stability and engage with the universe on a quest to create something new,
beautiful and unforeseen.  It all ends with compiler errors.

This step selects the relevant platform(s) for the built binaries.
"""
function step1(state::WizardState)
    print_wizard_logo(state.outs)

    # Select a platform
    msg = "\t\t\t# Step 1: Select your platforms\n\n"
    printstyled(state.outs, msg, bold=true)
    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    platform_select = request(terminal,
        "Make a platform selection",
        RadioMenu([
            "All Supported Platforms",
            "Select by Operating System",
            "Fully Custom Platform Choice",
        ]; charset=:ascii)
    )
    println(state.outs)

    # Set `state.platforms` accordingly
    result = nothing
    if platform_select == 1
        state.platforms = supported_platforms()
    elseif platform_select == 2
        oses = sort(unique(map(os, supported_platforms())))
        while true
            result = request(terminal,
                "Select operating systems",
                MultiSelectMenu(oses; charset=:ascii)
            )
            result = map(x->oses[x], collect(result))
            if isempty(result)
                println("Must select at least one operating system")
            else
                break
            end
        end
        state.platforms = collect(filter(x->os(x) in result, supported_platforms()))
    elseif platform_select == 3
        platfs = supported_platforms()
        while true
            result = request(terminal,
                "Select platforms",
                MultiSelectMenu(map(repr, platfs); charset=:ascii)
            )
            if isempty(result)
                println("Must select at least one platform")
            else
                break
            end
        end
        state.platforms = collect(map(x->platfs[x], collect(result)))
    else
        error("Somehow platform_select was not a valid choice!")
    end

    if any(p -> Sys.isapple(p), state.platforms) && !isfile(enable_apple_file()) && !macos_sdk_already_installed()
        # Ask the user if they accept to download the macOS SDK
        if accept_apple_sdk(state.ins, state.outs)
            touch(enable_apple_file())
        else
            # The user refused to download the macOS SDK
            println(state.outs)
            printstyled(state.outs, "Removing MacOS from the list of platforms...\n", bold=true)
            filter!(p -> !Sys.isapple(p), state.platforms)
        end
    end
    if isempty(state.platforms)
        # In case the user didn't accept the macOS SDK and macOS was the only
        # platform selected.
        error("No valid platform selected!")
    end
    println(state.outs)
end

function obtain_binary_deps(state::WizardState)
    msg = "\t\t\t# Step 2b: Obtain binary dependencies (if any)\n\n"
    printstyled(state.outs, msg, bold=true)

    q = "Do you require any (binary) dependencies? "
    state.dependencies = Dependency[]
    if yn_prompt(state, q, :n) == :y
        terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
        local resolved_deps
        jll_names = String[]
        while true
            jll_name = nonempty_line_prompt("package name", "Enter JLL package name:"; ins=state.ins, outs=state.outs)
            if !endswith(jll_name, "_jll")
                jll_name *= "_jll"
            end

            # Check to see if this JLL package name can be resolved:
            push!(jll_names, jll_name)
            all_resolved, resolved_deps = resolve_jlls(Dependency.(jll_names), outs=state.outs)

            if !all_resolved
                pop!(jll_names)
                if yn_prompt(state, "Unable to resolve \"$(jll_name)\"; enter a new one?", :y) != :y
                    break
                else
                    continue
                end
            end

            q = "Would you like to provide additional dependencies? "
            if yn_prompt(state, q, :n) != :y
                break
            end
        end
        # jll_names contains the valid names, resolved_deps potentially contains
        # unresolved deps so we filter them out here.
        state.dependencies = filter(x -> getname(x) ∈ jll_names, resolved_deps)
    end
    println(state.outs)
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
    state.source_files = SetupSource[]

    while true
        url, file = download_source(state)
        if url != "N"
            push!(state.source_urls, url)
            push!(state.source_files, file)
            println(state.outs)
        else
            if isempty(state.source_urls)
                printstyled(state.outs, "No URLs were given.\n", color=:red, bold=true)
                continue
            end
        end 
        q = "Would you like to download additional sources? "
        if yn_prompt(state, q, :n) != :y
            break
        end
    end
    println(state.outs)
end

function get_name_and_version(state::WizardState)
    ygg = LibGit2.GitRepo(get_yggdrasil())

    while state.name === nothing
        msg = "Enter a name for this project.  This will be used for filenames:"
        # Remove trailing `_jll` in case the user thinks this should be part of the name
        new_name = replace(nonempty_line_prompt("Name", msg; ins=state.ins, outs=state.outs),
                           r"_jll$" => "")

        if !Base.isidentifier(new_name)
            println(state.outs, "\"$(new_name)\" is an invalid identifier. Try again.")
            continue
        end

        # Check to see if this project name already exists
        if case_insensitive_repo_file_exists(ygg, yggdrasil_build_tarballs_path(new_name))
            println(state.outs, "A build recipe with that name already exists within Yggdrasil.")

            if yn_prompt(state, "Choose a new project name?", :y) != :n
                continue
            end
        end
        state.name = new_name
    end

    msg = "Enter a version number for this project:"
    while state.version === nothing
        try
            state.version = VersionNumber(nonempty_line_prompt("Version", msg; ins=state.ins, outs=state.outs))
        catch e
            if isa(e, ArgumentError)
                println(state.outs, e.msg)
                continue
            end
            rethrow(e)
        end
    end
end

@enum Compilers C=1 Go Rust
function get_compilers(state::WizardState)
    while state.compilers === nothing
        compiler_descriptions = Dict(C => "C/C++/Fortran", Go => "Go", Rust => "Rust")
        compiler_symbols = Dict(Int(C) => :c, Int(Go) => :go, Int(Rust) => :rust)
        terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
        result = nothing
        while true
            select_menu = MultiSelectMenu([compiler_descriptions[i] for i in instances(Compilers)]; charset=:ascii)
            select_menu.selected = Set([Int(C)])
            result = request(terminal,
                             "Select compilers for the project",
                             select_menu
                             )
            if isempty(result)
                println("Must select at least one platform")
            else
                break
            end
        end
        state.compilers = map(c -> compiler_symbols[c], collect(result))
    end
end

function get_preferred_version(state::WizardState, compiler::AbstractString,
                               available_versions=Vector{Integer})
    terminal = TTYTerminal("xterm", state.ins, state.outs, state.outs)
    message = "Select the preferred $(compiler) version (default: $(first(available_versions)))"
    version_selected = request(terminal, message, RadioMenu(string.(available_versions); charset=:ascii))
    if compiler == "GCC"
        state.preferred_gcc_version = available_versions[version_selected]
    elseif compiler == "LLVM"
        state.preferred_llvm_version = available_versions[version_selected]
    end
end

"""
    step2(state::WizardState)

This step obtains the source code to be built and required binary dependencies.
"""
function step2(state::WizardState)
    obtain_source(state)
    obtain_binary_deps(state)
    get_name_and_version(state)
    if yn_prompt(state, "Do you want to customize the set of compilers?", :n) == :y
        get_compilers(state)
        # Default GCC version is the oldest one
        get_preferred_version(state, "GCC", getversion.(available_gcc_builds))
        # Default LLVM version is the latest one
        get_preferred_version(state, "LLVM", getversion.(reverse(available_llvm_builds)))
    else
        state.compilers = [:c]
        # Default GCC version is the oldest one
        state.preferred_gcc_version = getversion(available_gcc_builds[1])
        # Default LLVM version is the latest one
        state.preferred_llvm_version = getversion(available_llvm_builds[end])
    end
end
