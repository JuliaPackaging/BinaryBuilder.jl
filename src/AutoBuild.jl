export build_tarballs, autobuild, print_artifact_toml, product_hashes_from_github_release, build
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256
using Pkg.TOML
import Pkg, Registrator


"""
    build_tarballs(ARGS, src_name, src_version, sources, script, platforms,
                   products, dependencies; kwargs...)

This should be the top-level function called from a `build_tarballs.jl` file.
It takes in the information baked into a `build_tarballs.jl` file such as the
`sources` to download, the `products` to build, etc... and will automatically
download, build and package the tarballs, generating a `build.jl` file when
appropriate.  Note that `ARGS` should be the top-level Julia `ARGS` command-
line arguments object.  This function does some rudimentary parsing of the
`ARGS`, call it with `--help` in the `ARGS` to see what it can do.
"""
function build_tarballs(ARGS, src_name, src_version, sources, script,
                        platforms, products, dependencies; kwargs...)
    # See if someone has passed in `--help`, and if so, give them the
    # assistance they so clearly long for
    if "--help" in ARGS
        println(strip("""
        Usage: build_tarballs.jl [target1,target2,...] [--verbose]
                                 [--debug] [--deploy] [--help]

        Options:
            targets             By default `build_tarballs.jl` will build a tarball
                                for every target within the `platforms` variable.
                                To override this, pass in a list of comma-separated
                                target triplets for each target to be built.  Note
                                that this can be used to build for platforms that
                                are not listed in the 'default list' of platforms
                                in the build_tarballs.jl script.

            --verbose           This streams compiler output to stdout during the
                                build which can be very helpful for finding bugs.
                                Note that it is colorized if you pass the
                                --color=yes option to julia, see examples below.

            --debug             This causes a failed build to drop into an
                                interactive shell for debugging purposes.

            --deploy            Deploy the built binaries to a github release,
                                autodetecting from the current git repository.

            --register=<depot>  Register into the given depot.  If no path is
                                given, defaults to `~/.julia`.

            --help              Print out this message.

        Examples:
            julia --color=yes build_tarballs.jl --verbose
                This builds all tarballs, with colorized output.

            julia build_tarballs.jl x86_64-linux-gnu,i686-linux-gnu
                This builds two tarballs for the two platforms given, with a
                minimum of output messages.
        """))
        return nothing
    end

    function check_flag(flag)
        flag_present = flag in ARGS
        ARGS = filter!(x -> x != flag, ARGS)
        return flag_present
    end

    # This sets whether we should build verbosely or not
    verbose = check_flag("--verbose")

    # This sets whether we drop into a debug shell on failure or not
    debug = check_flag("--debug")

    # This sets whether we are going to deploy our binaries to GitHub releases
    deploy = check_flag("--deploy")

    # This sets whether we are going to register, and if so, which 
    register = false
    register_path = Pkg.depots1()
    for f in ARGS
        if startswith(f, "--register")
            register = true

            if f != "--register"
                register_path = split(f, '=')[2]
            end
            ARGS = filter!(x -> x != f, ARGS)
            break
        end
    end

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    if length(ARGS) > 0
        platforms = platform_key_abi.(split(ARGS[1], ","))
    end

    # If we asked to deploy, make sure we have all the info before even starting to build
    if deploy || register
        # Check to see if this Artifact already exists within the Registry,
        # choose a version number that is greater than anything else existent.
        build_version = get_next_artifact_version(src_name, src_version)

        repo = get_repo_name()
        tag = get_tag_name(src_name, build_version)

        uuid = Pkg.Types.uuid5(Pkg.Types.uuid_artifact, "$(src_name)_jll")
    end

    if deploy && !haskey(ENV, "GITHUB_TOKEN")
        error("Must define a GITHUB_TOKEN environment variable to upload with `ghr`!")
    end

    @info("Building for $(join(triplet.(platforms), ", "))")
    # Build the given platforms using the given sources
    product_hashes = autobuild(pwd(), src_name, src_version, sources, script, platforms,
                         products, dependencies; verbose=verbose, debug=debug, kwargs...)

    # Upload binaries to GitHub, using `ghr`
    if deploy
        # Upload the binaries
        if verbose
            @info("Deploying binaries to release $(tag) on $(repo) via `ghr`...")
        end
        upload_to_github_releases(repo, tag, joinpath(pwd(), "products"); verbose=verbose)
    end

    if register
        if verbose
            @info("Registering new artifact version $(build_version)...")
        end

        # The location the binaries will be available from
        bin_path = "https://github.com/$(repo)/releases/download/$(tag)"
        
        # For each platform listed in the proudct_hashes, insert it into `versions_dict`
        version_info = Dict("artifacts" => Dict())
        for platform in sort(collect(keys(product_hashes)))
            fname, tarball_hash, git_hash = product_hashes[platform]
            version_info["artifacts"][platform] = Dict(
                "url" => "$(bin_path)/$(fname)",
                "tarball-hash-sha256" => tarball_hash,
                "git-tree-sha1" => git_hash,
            )
        end

        project = Pkg.Types.Project(Dict(
            "name" => "$(src_name)_jll",
            "uuid" => string(uuid),
            "version" => string(build_version),

            # No support for deps yet
            #"deps" => ,
        ))
        # Force Registrator to slap stuff into our global registry, for testing
        reg_uuid = TOML.parsefile(joinpath(Pkg.depots1(), "registries", "General", "Registry.toml"))["uuid"]
        Registrator.REGISTRIES[Registrator.DEFAULT_REGISTRY] = Pkg.Types.UUID(reg_uuid)
        Registrator.register(project, version_info; force_reset=false, registries_root=String(register_path), is_artifact=true)
    end

    return product_hashes
end

# Helper function to get things from ENV, returning `nothing`
# if they either don't exist or are empty
function get_ENV(key)
    if !haskey(ENV, key)
        return nothing
    end

    if isempty(ENV[key])
        return nothing
    end

    return ENV[key]
end

function find_parent_git_repo(path::AbstractString)
    # Canonicalize immediately
    path = abspath(path)

    # Walk upwards until we reach the root
    while dirname(path) != path
        try
            return LibGit2.GitRepo(path)
        catch
        end
        path = dirname(path)
    end
    return nothing
end

function get_repo_name()
    # Helper function to synthesize repository slug from environment variables
    function get_gitlab_repo_name()
        owner = get_ENV("CI_REPO_OWNER")
        name = get_ENV("CI_REPO_NAME")
        if owner != nothing && name != nothing
            return "$(owner)/$(name)"
        end
        return nothing
    end

    # Helper function to guess repository slug from git remote URL
    function read_git_origin()
        repo = find_parent_git_repo(".")
        if repo != nothing
            url = LibGit2.url(LibGit2.get(LibGit2.GitRemote, repo, "origin"))
            owner = basename(dirname(url))
            if occursin(":", owner)
                owner = owner[findlast(isequal(':'), owner)+1:end]
            end
            name = basename(url)
            if endswith(name, ".git")
                name = name[1:end-4]
            end
            return "$(owner)/$(name)"
        end
        return nothing
    end

    return something(
        get_ENV("TRAVIS_REPO_SLUG"),
        get_gitlab_repo_name(),
        read_git_origin(),
    )
end

function get_tag_name(src_name, build_version)
    # Helper function to guess tag from current commit taggedness
    function read_git_tag()
        repo = find_parent_git_repo(".")
        if repo != nothing
            head_gitsha = LibGit2.GitHash(LibGit2.head(repo))
            for tag in LibGit2.tag_list(repo)
                tag_gitsha = LibGit2.GitHash(LibGit2.GitCommit(repo, tag))
                if head_gitsha == tag_gitsha
                    return tag
                end
            end
        end
        return nothing
    end

    return something(
        get_ENV("TRAVIS_TAG"),
        get_ENV("CI_COMMIT_TAG"),
        read_git_tag(),
        "$(src_name)-v$(build_version)",
    )
end

function get_registry_path()
    return something(
        get_ENV("BINARYBUILDER_REGISTRY_PATH"),
        joinpath(Pkg.depots1(), "registries", "General"),
    )
end

function upload_to_github_releases(repo, tag, path; attempts::Int = 3, verbose::Bool = false)
    for attempt in 1:attempts
        try
            run(`ghr -replace -u $(dirname(repo)) -r $(basename(repo)) $(tag) $(path)`)
            return
        catch
            if verbose
                @info("`ghr` upload step failed, beginning attempt #$(attempt)...")
            end
        end
    end
    error("Unable to upload $(path) to GitHub repo $(repo) on tag $(tag)")
end

function get_next_artifact_version(src_name, src_version)
    ctx = Pkg.Types.Context()
    uuid = Pkg.Types.uuid5(Pkg.Types.uuid_artifact, "$(src_name)_jll")

    # If it does, we need to bump the build number up to the next value
    build_number = 0
    if any(isfile(joinpath(p, "Artifact.toml")) for p in Pkg.Operations.registered_paths(ctx.env, uuid))
        # Find largest version number that matches ours in the registered paths
        versions = VersionNumber[]
        for path in Pkg.Operations.registered_paths(ctx.env, uuid)
            append!(versions, Pkg.Compress.load_versions(path))
        end
        versions = filter(v -> (v.major == src_version.major) &&
                            (v.minor == src_version.minor) &&
                            (v.patch == src_version.patch) &&
                            (v.build isa Tuple{<:UInt}), versions)
        # Our build number must be larger than the maximum already present in the registry
        if !isempty(versions)
            build_number = maximum(versions).build + 1
        end
    end

    # Construct build_version (src_version + build_number)
    build_version = VersionNumber(src_version.major, src_version.minor,
                         src_version.patch, src_version.prerelease, (build_number,))
end

"""
    autobuild(dir::AbstractString, src_name::AbstractString,
              src_version::VersionNumber, sources::Vector,
              script::AbstractString, platforms::Vector,
              products::Function, dependencies::Vector;
              verbose::Bool = true, kwargs...)

Runs the boiler plate code to download, build, and package a source package
for a list of platforms.  `src_name` represents the name of the source package
being built (and will set the name of the built tarballs), `platforms` is a
list of platforms to build for, `sources` is a list of tuples giving
`(url, hash)` of all sources to download and unpack before building begins,
`script` is a string representing a shell script to run to build the desired
products, which are listed as `Product` objects within the vector returned by
the `products` function. `dependencies` gives a list of dependencies that
provide `build.jl` files that should be installed before building begins to
allow this build process to depend on the results of another build process.
Setting `debug` to `true` will cause a failed build to drop into an interactive
shell so that the build can be inspected easily.
"""
function autobuild(dir::AbstractString,
                   src_name::AbstractString,
                   src_version::VersionNumber,
                   sources::Vector,
                   script::AbstractString,
                   platforms::Vector,
                   products::Vector{<:Product},
                   dependencies::Vector;
                   verbose::Bool = false,
                   debug::Bool = false,
                   skip_audit::Bool = false,
                   ignore_audit_errors::Bool = true,
                   autofix::Bool = true,
                   kwargs...)
    # If we're on CI and we're not verbose, schedule a task to output a "." every few seconds
    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            @info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # This is what we'll eventually return
    product_hashes = Dict()

    # If we end up packaging any local directories into tarballs, we'll store them here
    mktempdir() do tempdir
        # We must prepare our sources.  Download them, hash them, etc...
        sources = Any[s for s in sources]
        for idx in 1:length(sources)
            # If the given source is a local path that is a directory, package it up and insert it into our sources
            if typeof(sources[idx]) <: AbstractString
                if !isdir(sources[idx])
                    error("Sources must either be a pair (url => hash) or a local directory")
                end

                # Package up this directory and calculate its hash
                tarball_path = joinpath(tempdir, basename(sources[idx]) * ".tar.gz")
                package(sources[idx], tarball_path; verbose=verbose)
                tarball_hash = open(tarball_path, "r") do f
                    bytes2hex(sha256(f))
                end

                # Move it to a filename that has the hash as a part of it (to avoid name collisions)
                tarball_pathv = joinpath(tempdir, string(tarball_hash, "-", basename(sources[idx]), ".tar.gz"))
                mv(tarball_path, tarball_pathv)

                # Now that it's packaged, store this into sources[idx]
                sources[idx] = (tarball_pathv => tarball_hash)
            elseif typeof(sources[idx]) <: Pair
                src_url, src_hash = sources[idx]

                # If it's a .git url, clone it
                if endswith(src_url, ".git")
                    src_path = storage_dir("downloads", basename(src_url))

                    # If this git repository already exists, ensure that its origin remote actually matches
                    if isdir(src_path)
                        origin_url = LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.url(LibGit2.get(LibGit2.GitRemote, repo, "origin"))
                        end

                        # If the origin url doesn't match, wipe out this git repo.  We'd rather have a
                        # thrashed cache than an incorrect cache.
                        if origin_url != src_url
                            rm(src_path; recursive=true, force=true)
                        end
                    end

                    if isdir(src_path)
                        # If we didn't just mercilessly obliterate the cached git repo, use it!
                        LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                            LibGit2.fetch(repo)
                        end
                    else
                        # If there is no src_path yet, clone it down.
                        repo = LibGit2.clone(src_url, src_path; isbare=true)
                    end
                else
                    if isfile(src_url)
                        # Immediately abspath() a src_url so we don't lose track of
                        # sources given to us with a relative path
                        src_path = abspath(src_url)

                        # And if this is a locally-sourced tarball, just verify
                        verify(src_path, src_hash; verbose=verbose)
                    else
                        # Otherwise, download and verify
                        src_path = storage_dir("downloads", basename(src_url))
                        download_verify(src_url, src_hash, src_path; verbose=verbose)
                    end
                end

                # Now that it's downloaded, store this into sources[idx]
                sources[idx] = (src_path => src_hash)
            else
                error("Sources must be either a `URL => hash` pair, or a path to a local directory")
            end
        end

        # Our build products will go into ./products
        out_path = joinpath(dir, "products")
        try mkpath(out_path) catch; end

        # Convert from tuples to arrays, if need be
        src_paths, src_hashes = collect.(collect(zip(sources...)))

        for platform in platforms
            target = triplet(platform)

            # We build in a platform-specific directory
            build_path = joinpath(pwd(), "build", target)
            mkpath(build_path)

            prefix, ur = setup_workspace(
                build_path,
                src_paths,
                src_hashes,
                dependencies,
                platform;
                verbose=verbose,
                kwargs...,
            )

            # We're going to create a project and install all dependent packages within
            # it, then create symlinks from those installed products to our 
            dep_paths = String[]
            if !isempty(dependencies)
                deps_project = joinpath(build_path, ".project")
                Pkg.activate(deps_project) do
                    Pkg.add(dependencies)

                    m = Module(:__anon__)
                    for dep in dependencies
                        dep = Symbol(dep)
                        Core.eval(m, :(using $(dep)))
                        push!(dep_paths, Core.eval(m, :(dirname(dirname(pathof($(dep)))))))
                    end
                end

                # Symlink all the deps into the prefix
                for dep_path in dep_paths
                    symlink_tree(dep_path, prefix.path)
                end
            end

            # Set up some bash traps
            trapper_wrapper = """
            # Stop if we hit any errors.
            set -e

            # NABIL TODO: Move this into the Rootfs
            # If we're running as `bash`, then use the `DEBUG` and `ERR` traps
            if [ \$(basename \$0) = "bash" ]; then
                trap save_history DEBUG
                trap "save_env" EXIT
                trap "save_env; save_srcdir" INT TERM ERR

                # Swap out srcdir from underneath our feet if we've got our `ERR`
                # traps set; if we don't have this, we get very confused.  :P
                tmpify_srcdir
            else
                # If we're running in `sh` or something like that, we need a
                # slightly slimmer set of traps. :(
                trap "save_env" EXIT INT TERM
            fi

            $(script)
            """

            logpath = joinpath(logdir(prefix), "$(src_name).log")
            did_succeed = run(ur, `/bin/bash -l -c $(trapper_wrapper)`, logpath; verbose=verbose)
            if !did_succeed
                if debug
                    @warn("Build failed, launching debug shell")
                    run_interactive(ur, `/bin/bash -l -i`)
                end
                msg = "Build for $(src_name) on $(triplet(platform)) did not complete successfully\n"
                error(msg)
            end

            # Run an audit of the prefix to ensure it is properly relocatable
            if !skip_audit
                audit_result = audit(prefix; platform=platform,
                                             verbose=verbose, autofix=autofix) 
                if !audit_result && !ignore_audit_errors
                    msg = replace("""
                    Audit failed for $(prefix.path).
                    Address the errors above to ensure relocatability.
                    To override this check, set `ignore_audit_errors = true`.
                    """, '\n' => ' ')
                    error(strip(msg))
                end
            end

            # Finally, warn if something isn't satisfied
            for p in products
                if !satisfied(p, prefix; verbose=verbose, platform=platform)
                    @warn("Built $(src_name) but $(variable_name(p)) still unsatisfied!")
                end
            end

            # Unsymlink all the deps from the prefix
            for dep_path in dep_paths
                unsymlink_tree(dep_path, prefix.path)
            end

            # Generate wrapper Julia code for the given products
            code_dir = joinpath(prefix, "src")
            mkpath(code_dir)
            open(joinpath(code_dir, "$(src_name)_jll.jl"), "w") do io
                print(io, """
                # Autogenerated wrapper script for $(src_name)_jll
                module $(src_name)_jll
                using Libdl

                export $(join(variable_name.(products), ", "))
                """)
                for dep in dependencies
                    println(io, "using $(dep)_jll")
                end

                # The LIBPATH is called different things on different platforms
                if platform isa Windows
                    LIBPATH_env = "PATH"
                    pathsep = ';'
                elseif platform isa MacOS
                    LIBPATH_env = "DYLD_FALLBACK_LIBRARY_PATH"
                    pathsep = ':'
                else
                    LIBPATH_env = "LD_LIBRARY_PATH"
                    pathsep = ':'
                end

                print(io, """
                ## Global variables
                const PATH_list = String[]
                const LIBPATH_list = String[]
                PATH = ""
                LIBPATH = ""
                LIBPATH_env = $(repr(LIBPATH_env))
                """)

                # Next, begin placing products
                function global_declaration(p::LibraryProduct)
                    # A library product's public interface is a handle
                    return """
                    # This will be filled out by __init__()
                    $(variable_name(p))_handle = C_NULL

                    # This must be `const` so that we can use it with `ccall()`
                    const $(variable_name(p)) = $(repr(get_soname(locate(p, prefix; platform=platform))))
                    """
                end

                function global_declaration(p::ExecutableProduct)
                    vp = variable_name(p)
                    # An executable product's public interface is a do-block wrapper function
                    return """
                    function $(vp)(f::Function; adjust_PATH::Bool = true, adjust_LIBPATH::Bool = true)
                        global PATH, LIBPATH
                        env_mapping = Dict()
                        if adjust_PATH
                            if !isempty(get(ENV, "PATH", ""))
                                env_mapping["PATH"] = string(ENV["PATH"], $(repr(pathsep)), PATH)
                            else
                                env_mapping["PATH"] = PATH
                            end
                        end
                        if adjust_LIBPATH
                            if !isempty(get(ENV, LIBPATH_env, ""))
                                env_mapping[LIBPATH_env] = string(ENV[LIBPATH_env], $(repr(pathsep)), LIBPATH)
                            else
                                env_mapping[LIBPATH_env] = LIBPATH
                            end
                        end
                        withenv(env_mapping) do
                            f($(vp)_path)
                        end
                    end
                    """
                end

                function global_declaration(p::FileProduct)
                    return """
                    # This will be filled out by __init__()
                    $(variable_name(p)) = ""
                    """
                end

                # Create relative path mappings that are compile-time constant, and mutable
                # mappings that are initialized by __init__() at load time.
                for p in products
                    vp = variable_name(p)
                    p_relpath = relpath(locate(p, prefix; platform=platform), prefix.path)
                    print(io, """
                    # Relative path to `$(vp)`
                    const $(vp)_relpath = $(repr(p_relpath))

                    # This will be filled out by __init__() for all products
                    $(vp)_path = ""

                    # $(vp)-specific global declaration
                    $(global_declaration(p))
                    """)
                end

                print(io, """
                \"\"\"
                Open all libraries
                \"\"\"
                function __init__()
                    global prefix = abspath(joinpath(@__DIR__, ".."))

                    # Initialize PATH and LIBPATH environment variable listings
                    global PATH_list, LIBPATH_list
                """)
                for dep in dependencies
                    print(io, """
                        append!(PATH_list, $(dep)_jll.PATH_list)
                        append!(LIBPATH_list, $(dep)_jll.LIBPATH_list)
                    """)
                end

                for p in products
                    vp = variable_name(p)

                    # Initialize $(vp)_path
                    print(io, """
                        global $(vp)_path = abspath(joinpath(prefix, $(vp)_relpath))
                    """)

                    # If `p` is a `LibraryProduct`, dlopen() it right now!
                    if p isa LibraryProduct
                        print(io, """
                            # Manually `dlopen()` this right now so that future invocations
                            # of `ccall` with its `SONAME` will find this path immediately.
                            global $(vp)_handle = dlopen($(vp)_path)
                            push!(LIBPATH_list, dirname($(vp)_path))
                        """)
                    elseif p isa ExecutableProduct
                        println(io, "    push!(PATH_list, dirname($(vp)_path))")
                    end
                end

                print(io, """
                    # Filter out duplicate and empty entries in our PATH and LIBPATH entries
                    filter!(!isempty, unique!(PATH_list))
                    filter!(!isempty, unique!(LIBPATH_list))
                    global PATH = join(PATH_list, $(repr(pathsep)))
                    global LIBPATH = join(LIBPATH_list, $(repr(pathsep)))

                    # Add each element of LIBPATH to our DL_LOAD_PATH (necessary on platforms
                    # that don't honor our "already opened" trick)
                    for lp in LIBPATH_list
                        push!(DL_LOAD_PATH, lp)
                    end
                end  # __init__()
                """)

                # End the module
                print(io, """
                end  # module $(src_name)_jll
                """)
            end

            # Add a Project.toml
            get_uuid(name) = Pkg.Types.uuid5(Pkg.Types.uuid_artifact, "$(name)_jll")
            project = Dict(
                "name" => "$(src_name)_jll",
                "uuid" => get_uuid(src_name),
                "version" => src_version,
                "deps" => Dict("$(dep)_jll" => get_uuid(dep) for dep in dependencies),
            )
            # Always add Libdl as a dependency
            project["deps"]["Libdl"] = first([u for (u, n) in Pkg.Types.stdlib() if n == "Libdl"])
            open(joinpath(prefix, "Project.toml"), "w") do io
                Pkg.TOML.print(io, project)
            end

            # Once we're built up, go ahead and package this prefix out
            tarball_path, tarball_hash, git_hash = package(
                prefix,
                joinpath(out_path, src_name),
                src_version;
                platform=platform,
                verbose=verbose,
                force=true,
            )
            product_hashes[target] = (
                basename(tarball_path),
                tarball_hash,
                git_hash,
            )

            # Destroy the workspace
            rm(dirname(prefix.path); recursive=true)

            # If the whole build_path is empty, then remove it too.  If it's not, it's probably
            # because some other build is doing something simultaneously with this target, and we
            # don't want to mess with their stuff.
            if isempty(readdir(build_path))
                rm(build_path; recursive=true)
            end
        end
    end

    if (haskey(ENV, "TRAVIS") || haskey(ENV, "CI")) && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Return our product hashes
    return product_hashes
end
