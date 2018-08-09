"""
    normalize_name(file::AbstractString)

Given a filename, normalize it, stripping out extensions.  E.g. the file path
`"foo/libfoo.tar.gz"` would get mapped to `"libfoo"`.
"""
function normalize_name(file::AbstractString)
    file = basename(file)
    idx = findfirst(isequal('.'), file)
    if idx !== nothing
        file = file[1:prevind(file, idx)]
    end
    # Strip -123, which is a common thing for libraries on windows
    idx = findlast(isequal('-'), file)
    if idx !== nothing && all(isnumber, file[nextind(file, idx):end])
        file = file[1:prevind(file, idx)]
    end
    return file
end

"""
    filter_object_files(files)

Given a list of files, filter out any that cannot be opened by `readmeta()`
from `ObjectFile`.
"""
function filter_object_files(files)
    return filter(files) do f
        try
            readmeta(f) do oh
                return true
            end
        catch e
            # If it was just a MagicMismatch, then return false for this file
            if isa(e, ObjectFile.MagicMismatch)
                return false
            end

            # If it was an EOFError (e.g. this was an empty file) then return false
            if isa(e, EOFError)
                return false
            end

            # If something else wrong then rethrow that error and pass it up
            rethrow(e)
            return false
        end
    end
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
    prefix_files = filter_object_files(prefix_files)
    # Check if we can load them as an object file
    prefix_files = filter(prefix_files) do f
        readmeta(f) do oh
            if !is_for_platform(oh, platform)
                if !silent
                    @warn("Skipping binary `$f` with incorrect platform")
                end
                return false
            end
            return true
        end
    end

    norm_prefix_files = Set(map(normalize_name, prefix_files))
    norm_files = Set(map(normalize_name, files))
    d = setdiff(norm_files, norm_prefix_files)
    if !isempty(d)
        if !silent
            @warn("Could not find correspondences for $(join(d, ' '))")
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
        ur = preferred_runner()(
            prefix.path,
            cwd = "/workspace/",
            platform = Linux(:x86_64))
        run_interactive(ur, `/usr/bin/vi /workspace/script`;
                        stdin=state.ins, stdout=state.outs, stderr=state.outs)

        # Once the user is finished, read the script back in
        script = String(read(path))
    end
    return script
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

function script_for_dep(dep, install_dir)
    # If dep is a pair, peel it to override install_dir
    if isa(dep, Pair)
        dep, install_dir = dep
    end

    # Since remote dependencies are most common, we default plain strings to
    # this in order to keep the build scripts small
    if isa(dep, String)
        dep = RemoteBuildDependency(dep, nothing)
    end

    if isa(dep, InlineBuildDependency)
        script = dep.script
    elseif isa(dep, RemoteBuildDependency)
        script = dep.script === nothing ? String(HTTP.get(dep.url).body) :
            dep.script
    end
    return script, install_dir
end

"""
    setup_workspace(build_path::String, src_paths::Vector,
                    src_hashes::Vector, platform::Platform,
                    extra_env::Dict{String, String};
                    verbose::Bool = false, tee_stream::IO = stdout,
                    downloads_dir = nothing)

Sets up a workspace within `build_path`, creating the directory structure
needed by further steps, unpacking the source within `build_path`, and defining
the environment variables that will be defined within the sandbox environment.

This method returns the `Prefix` to install things into, and the runner
that can be used to launch commands within this workspace.
"""
function setup_workspace(build_path::AbstractString, src_paths::Vector,
                         src_hashes::Vector, dependencies::Vector,
                         platform::Platform,
                         extra_env::Dict{String, String} =
                             Dict{String, String}();
                         verbose::Bool = false,
                         tee_stream::IO = stdout,
                         downloads_dir = nothing)
    # Use a random nonce to make detection of paths in embedded binary easier
    nonce = randstring()
    mkdir(joinpath(build_path, nonce))

    # We now set up two directories, one as a source dir, one as a dest dir
    srcdir = joinpath(build_path, nonce, "srcdir")
    destdir = joinpath(build_path, nonce, "destdir")
    metadir = joinpath(build_path, nonce, "metadir")
    mkdir(srcdir); mkdir(destdir); mkdir(metadir)

    # Create a runner to work inside this workspace with the nonce built-in
    ur = preferred_runner()(
        joinpath(build_path, nonce),
        cwd = "/workspace/srcdir",
        platform = platform,
        extra_env = merge(extra_env,
            Dict(
                "prefix" => "/workspace/destdir",
                "WORKSPACE" => "/workspace",
                "PS1" => "sandbox:\${PWD//\$WORKSPACE/\\\\\$WORKSPACE}\\\$ "
             )
        ),
        verbose = verbose,
        workspaces = [metadir => "/meta"],
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
            if verbose
                push!(cmds, "echo \"Extracting $(basename(src_path))...\"")
            end

            # For consistency, we use the tar inside the sandbox to unpack
            cp(src_path, joinpath(srcdir, basename(src_path)))
            if endswith(src_path, ".tar") || endswith(src_path, ".tar.gz") ||
               endswith(src_path, ".tgz") || endswith(src_path, ".tar.bz") ||
               endswith(src_path, ".tar.bz2") || endswith(src_path, ".tar.xz") ||
               endswith(src_path, ".tar.Z")
                push!(cmds, "tar xof $(basename(src_path))")
            elseif endswith(src_path, ".zip")
                push!(cmds, "unzip -q $(basename(src_path))")
            end
            push!(cmds, "rm $(basename(src_path))")
        end
    end

    # If we haven't been given a downloads_dir, just dump it all into `srcdir`:
    if downloads_dir == nothing
        downloads_dir = srcdir
    end

    # For each dependency, install it into the prefix
    for dep in dependencies
        script, install_dir = script_for_dep(dep, destdir)
        m = Module(:__anon__)
        Core.eval(m, quote
            using BinaryProvider

            # Force the script to download for this platform.
            platform_key() = $platform

            # We don't want any deps files being written out
            function write_deps_file(args...; kwargs...) end

            # Override @__DIR__ to return the destination directory,
            # so that things get installed into there.  This is a protection
            # against older scripts that ignore `ARGS[1]`, which is set below.
            # Eventually we should be able to forgo this skullduggery.
            macro __DIR__(args...); return $destdir; end

            # Override install() to cache in our downloads directory, to
            # ignore platforms, and to be verbose if we want it to be.
            function install(url, hash; kwargs...)
                BinaryProvider.install(url, hash;
                    tarball_path=joinpath($downloads_dir, basename(url)),
                    ignore_platform=true,
                    verbose=$verbose,
                    kwargs...,
                )
            end
            ARGS = [$install_dir]
            include_string($(m), $(script))
        end)
    end

    # Run the cmds defined above
    if !isempty(cmds)
        run(ur, `/bin/bash -c $(join(cmds, '\n'))`, ""; verbose=verbose, tee_stream=tee_stream)
    end

    # Return the prefix and the runner
    return Prefix(destdir), ur
end

"""
    Change the script. This will invalidate all platforms to make sure we later
    verify that they still build with the new script.
"""
function change_script!(state, script)
    state.history = script
    empty!(state.validated_platforms)
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

    logo = replace(logo, " o " => " $(green)o$(normal) ")
    logo = replace(logo, "o*o" => "$(red)o$(blue)*$(magenta)o$(normal)")

    logo = replace(logo, ".--*" => "$(red).$(green)-$(magenta)-$(blue)*$(normal)")

    logo = replace(logo, "\$." => " $(blue).$(normal)")
    logo = replace(logo, "\$E" => " $(red)E$(normal)")
    logo = replace(logo, "\$L" => " $(green)L$(normal)")
    logo = replace(logo, "\$F" => " $(magenta)F$(normal)")

    print(outs, logo)
end
