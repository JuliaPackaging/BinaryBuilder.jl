"""
    normalize_name(file::AbstractString)

Given a filename, normalize it, stripping out extensions.  E.g. the file path
`"foo/libfoo.tar.gz"` would get mapped to `"libfoo"`.
"""
function normalize_name(file::AbstractString)
    file = basename(file)
    idx = findfirst(file, '.')
    if idx != 0
        file = file[1:prevind(file, idx)]
    end
    # String -123, which is a common thing for libraries on windows
    idx = findlast(file, '-')
    if idx != 0 && all(isnumber, file[nextind(file, idx):end])
        file = file[1:prevind(file, idx)]
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
        ur = preferred_runner()(
            prefix.path,
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

function script_for_dep(dep)
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
    script
end

"""
    setup_workspace(build_path::AbstractString, src_paths::Vector,
                    src_hashes::Vector, platform::Platform,
                    extra_env::Dict{String, String};
                    verbose::Bool = false, tee_stream::IO = STDOUT)

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
                         verbose::Bool = false, tee_stream::IO = STDOUT)

    # Use a random nonce to make detection of paths in embedded binary easier
    nonce = randstring()
    mkdir(joinpath(build_path, nonce))

    # We now set up two directories, one as a source dir, one as a dest dir
    srcdir = joinpath(build_path, nonce, "srcdir")
    destdir = joinpath(build_path, nonce, "destdir")
    mkdir(srcdir); mkdir(destdir)

    # Create a runner to work inside this workspace with the nonce built-in
    ur = preferred_runner()(
        joinpath(build_path, nonce),
        cwd = "/workspace/srcdir",
        platform = platform,
        extra_env = merge(extra_env,
            merge(destdir_envs("/workspace/destdir"),
                Dict(
                    "WORKSPACE" => "/workspace",
                    "PS1" => "sandbox:\${PWD//\$WORKSPACE/\\\\\$WORKSPACE}\\\$ "
                ))
        ),
        verbose = verbose,
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
               endswith(src_path, ".tgz") || endswith(src_path, ".tar.bz") ||
               endswith(src_path, ".tar.xz") || endswith(src_path, ".tar.Z")
                push!(cmds, "tar xof $(basename(src_path))")
            elseif endswith(src_path, ".zip")
                push!(cmds, "unzip -q $(basename(src_path))")
            end
            push!(cmds, "rm $(basename(src_path))")
        end
    end

    # For each dependency, install it into the prefix
    for dep in dependencies
        script = script_for_dep(dep)
        m = Module(:__anon__)
        eval(m, quote
            using BinaryProvider
            platform_key() = $platform
            macro write_deps_file(args...); end
            install(args...; kwargs...) = BinaryProvider.install(args...; kwargs..., ignore_platform=true, verbose=$verbose)
            ARGS = [$destdir]
            include_string($(script))
        end)
    end

    # Run the cmds defined above
    run(ur, `/bin/bash -c $(join(cmds, '\n'))`, ""; verbose=verbose, tee_stream=tee_stream)

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

    logo = replace(logo, " o ", " $(green)o$(normal) ")
    logo = replace(logo, "o*o", "$(red)o$(blue)*$(magenta)o$(normal)")

    logo = replace(logo, ".--*", "$(red).$(green)-$(magenta)-$(blue)*$(normal)")

    logo = replace(logo, "\$.", " $(blue).$(normal)")
    logo = replace(logo, "\$E", " $(red)E$(normal)")
    logo = replace(logo, "\$L", " $(green)L$(normal)")
    logo = replace(logo, "\$F", " $(magenta)F$(normal)")

    print(outs, logo)
end
