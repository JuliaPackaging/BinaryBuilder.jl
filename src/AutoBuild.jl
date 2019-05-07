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
            targets         By default `build_tarballs.jl` will build a tarball
                            for every target within the `platforms` variable.
                            To override this, pass in a list of comma-separated
                            target triplets for each target to be built.  Note
                            that this can be used to build for platforms that
                            are not listed in the 'default list' of platforms
                            in the build_tarballs.jl script.

            --verbose       This streams compiler output to stdout during the
                            build which can be very helpful for finding bugs.
                            Note that it is colorized if you pass the
                            --color=yes option to julia, see examples below.

            --debug         This causes a failed build to drop into an
                            interactive shell for debugging purposes.

            --deploy        Deploy the built binaries to a github release, deploy
                            to local registry.

            --help          Print out this message.

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

    # The sets whether we are going to deploy our binaries to GitHub releases and `General`
    deploy = check_flag("--deploy")

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    if length(ARGS) > 0
        should_override_platforms = true
        platforms = platform_key_abi.(split(ARGS[1], ","))
    end

    # If we're running on CI and this is a tagged release, automatically
    # determine bin_path by building up a URL
    @info("Building for $(join(triplet.(platforms), ", "))")

    # Build the given platforms using the given sources
    product_hashes = autobuild(pwd(), src_name, src_version, sources, script, platforms,
                         products, dependencies; verbose=verbose, debug=debug, kwargs...)

    # Upload binaries to GitHub, using `ghr`
    if deploy
        repo = get_repo_name()
        tag = get_tag_name()

        # The location the binaries will be available from
        bin_path = "https://github.com/$(repo)/releases/download/$(tag)"

        # Upload the binaries
        if verbose
            @info("Deploying binaries to GitHub Releases via `ghr`...")
        end
        upload_to_github_releases(repo, tag, joinpath(pwd(), "products"); verbose=verbose)

        # Check to see if this Artifact already exists within the Registry,
        # choose a version number that is greater than anything else existent.
        build_version = get_next_artifact_version(src_name, src_version)

        # Register this new artifact version
        pkg = Pkg.Types.ArtifactSpec(;name=src_name, uuid=uuid, version=build_version)
        
        # For each platform listed in the proudct_hashes, insert it into `versions_dict`
        version_info = Dict("artifacts" => Dict())
        for platform in sort(collect(keys(product_hashes)))
            fname, hash, products = product_hashes[platform]
            version_info["artifacts"][platform] = Dict(
                "url" => "$(bin_path)/$(fname)",
                "hash" => hash,
                "products" => products,
            )
        end

        if verbose
            @info("Registering new artifact version $(build_version)...")
        end
        Registrator.register(pkg, version_info)
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

function get_tag_name()
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
            run(`ghr -u $(dirname(repo)) -r $(basename(repo)) $(tag) $(path)`)
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
                   products::Function,
                   dependencies::Vector;
                   verbose::Bool = true,
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

        for platform in platforms
            target = triplet(platform)

            # We build in a platform-specific directory
            build_path = joinpath(pwd(), "build", target)
            try mkpath(build_path) catch; end

            src_paths, src_hashes = collect(zip(sources...))

            # Convert from tuples to arrays, if need be
            src_paths = collect(src_paths)
            src_hashes = collect(src_hashes)
            prefix, ur = setup_workspace(
                build_path,
                src_paths,
                src_hashes,
                dependencies,
                platform;
                verbose=verbose,
                downloads_dir=storage_dir("downloads"),
                extract_kwargs(kwargs, (:preferred_gcc_version,))...,
            )

            # Don't keep the downloads directory around
            rm(joinpath(prefix, "downloads"); force=true, recursive=true)

            # Collect dependency manifests so that our auditing doesn't touch these files that
            # were installed by dependencies
            manifest_dir = joinpath(prefix, "manifests")
            dep_manifests = if isdir(manifest_dir)
               [joinpath(prefix, "manifests", f) for f in readdir(manifest_dir)]
            else
                String[]
            end

            # Run the build, get paths to the concrete products within the Prefix
            concrete_products = build(ur,
                src_name,
                products(prefix),
                script,
                platform,
                prefix;
                verbose=verbose,
                ignore_manifests=dep_manifests,
                extract_kwargs(kwargs, (:force, :autofix, :ignore_audit_errors,
                                        :skip_audit, :bootstrap, :debug))...,
            )

            # Remove the files of any dependencies
            for dependency in dependencies
                dep_script = script_for_dep(dependency, prefix.path)[1]
                m = Module(:__anon__)
                Core.eval(m, quote
                    using BinaryProvider, Pkg
                    # Override BinaryProvider functionality so that it doesn't actually install anything
                    platform_key() = $platform
                    platform_key_abi() = $platform
                    function write_deps_file(args...; kwargs...); end
                    function install(args...; kwargs...); end

                    # Include build.jl file to extract download_info
                    ARGS = [$(prefix.path)]
                end)
                include_string(m, dep_script)
                Core.eval(m, quote
                    # Grab the information we need in order to extract a manifest, then uninstall it
                    url, hash = choose_download(download_info, platform_key_abi())
                    manifest_path = BinaryProvider.manifest_from_url(url; prefix=prefix)
                    BinaryProvider.uninstall(manifest_path; verbose=$verbose)
                end)
            end

            # Once we're built up, go ahead and package this prefix out
            tarball_path, tarball_hash = package(
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
                concrete_products,
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

function build(runner::Runner, name::AbstractString,
               products::Vector{P}, script::AbstractString,
               platform::Platform, prefix::Prefix;
               verbose::Bool = false, force::Bool = false,
               autofix::Bool = true, ignore_audit_errors::Bool = true,
               skip_audit::Bool = false, bootstrap::Bool = bootstrap_mode,
               ignore_manifests::Vector = [], debug::Bool = false) where {P <: Product}
    # First, look to see whether our products are satisfied or not
    if isempty(products)
        # If we've been given no products, always build and always say it's satisfied
        s = product -> true
        l = product -> nothing
        should_build = true
    else
        s = p -> satisfied(p; verbose=verbose, platform=platform, isolate=true)
        l = p -> locate(p; verbose=verbose, platform=platform)
        should_build = !all(s(p) for p in products)
    end

    # If it is not satisfied, (or we're forcing the issue) build it
    if force || should_build
        # Verbose mode tells us what's going on
        if verbose
            if !should_build
                @info("Force-building $(name) despite its satisfaction")
            else
                @info("Building $(name) as it is unsatisfied")
            end
        end

        # We setup our shell session to do three things:
        #   - Save history on every command issued (so we have a fake `~/.bash_history`)
        #   - Save environment on quit (so that we can regenerate all environment variables
        #     when we're debugging, etc...)
        #   - Copy the current srcdir over to disk if something breaks.  This is done so
        #     that if we want to debug a build halfway through, we can get at it.  We normally
        #     build with a tmpfs mounted at `$WORKSPACE/srcdir`.
        trapper_wrapper = """
        # Stop if we hit any errors.
        set -e

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

        logpath = joinpath(logdir(prefix), "$(name).log")
        did_succeed = run(runner, `/bin/bash -l -c $(trapper_wrapper)`, logpath; verbose=verbose)
        if !did_succeed
            if debug
                @warn("Build failed, launching debug shell")
                run_interactive(runner, `/bin/bash -l -i`)
            end
            msg = "Build for $(name) on $(triplet(platform)) did not complete successfully\n"
            error(msg)
        end

        # Run an audit of the prefix to ensure it is properly relocatable
        if !skip_audit
            audit_result = audit(prefix; platform=platform,
                                 verbose=verbose, autofix=autofix,
                                 ignore_manifests=ignore_manifests) 
            if !audit_result && !ignore_audit_errors
                msg = replace("""
                Audit failed for $(prefix.path).
                Address the errors above to ensure relocatability.
                To override this check, set `ignore_audit_errors = true`.
                """, '\n' => ' ')
                error(strip(msg))
            end
        end

        # Finally, check to see if we are now satisfied
        if !all(s(p) for p in products)
            if verbose
                @warn("Built $(name) but still unsatisfied!")
            end
        end
    elseif !should_build && verbose
        @info("Not building as $(name) is already satisfied")
    end

    # Return "concretized products", e.g. a mapping of variable name to actual
    # path.  We ensure these are relative to the prefix path.  We also ensure
    # that LibraryProducts point to a path that is the same as their SONAME.
    ppath = abspath(prefix.path)
    function concretize(p::Product)
        return relpath(l(p), ppath)
    end
    function concretize(p::LibraryProduct)
        # First locate the library, propagating `nothing` appropriately
        path = l(p)
        if path === nothing
            return nothing
        end

        # Get the SONAME, if it exists
        soname = get_soname(path)
        if soname === nothing
            return relpath(path, ppath)
        end

        # If it does, use that file path as the canonical path.
        return relpath(joinpath(dirname(path), soname), ppath)
    end
    
    return Dict(variable_name(p) => concretize(p) for p in products)
end

function print_artifact_toml(io::IO, src_name::AbstractString)
    toml = Dict(
        # Basic information about this artifact bundle
        "name" => "$(src_name)_jll",
        "uuid" => Pkg.Types.uuid5(Pkg.Types.uuid_artifact, "$(src_name)_jll"),
    )

    # Write the whole thing out to the given io
    return TOML.print(io, toml)
end

function update_versions_toml(io::IO, src_name::AbstractString,
                             src_version::VersionNumber, products::Vector,
                             product_hashes::Dict, bin_path::AbstractString)
    # Parse what already exists
    seekstart(io)
    toml = TOML.parse(io)

    if !haskey(toml, string(src_version))
        toml = Dict()
    end
    version_info = toml[string(src_version)]

    if !haskey(version_info, "artifacts")
        version_info["artifacts"] = Dict()
    end
    artifact_info = version_info["artifacts"]

    # For each platform listed in the proudct_hashes, insert it into `versions_dict`
    for platform in sort(collect(keys(product_hashes)))
        fname, hash, products = product_hashes[platform]
        artifact_info[platform] = Dict(
            "url" => "$(bin_path)/$(fname)",
            "hash" => hash,
            "products" => products,
        )
    end

    # Spit out the new toml file
    seekstart(io)
    truncate(io, 0)
    return TOML.print(io, toml)
end

function product_hashes_from_dir(dir_path::AbstractString; verbose::Bool = false)
    product_hashes = Dict()
    for filepath in [joinpath(dir_path, f) for f in readdir(dir_path) if endswith(f, ".tar.gz")]
        # For each asset (tarball), download it
        # Hash it
        hash = open(filepath) do file
            return bytes2hex(sha256(file))
        end

        # Then fit it into our product_hashes
        file_triplet = triplet(extract_platform_key(filepath))
        product_hashes[file_triplet] = (basename(filepath), hash)

        if verbose
            @info("Calculated $hash for $(basename(filepath))")
        end
    end

    return product_hashes
end

"""
If you have a sharded build on Github, it would be nice if we could get an auto-generated
`build.jl` just like if we build serially.  This function eases the pain by reconstructing
it from a releases page.
"""
function product_hashes_from_github_release(repo_name::AbstractString, tag_name::AbstractString;
                                            product_filter::AbstractString = "",
                                            verbose::Bool = false)
    # Get list of files within this release
    release = gh_get_json(DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)", auth=github_auth())

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        # Short-circuit build.jl because that's quite often there.  :P
        if startswith(filename, "build") && endswith(filename, ".jl")
            return false
        end

        unknown_platform = typeof(extract_platform_key(filename)) <: UnknownPlatform
        if unknown_platform && verbose
            @info("Ignoring file $(filename); can't extract its platform key")
        end
        return !unknown_platform
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]
    assets = [a for a in assets if occursin(product_filter, a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            # For each asset (tarball), download it
            filepath = joinpath(d, asset["name"])
            url = asset["browser_download_url"]
            BinaryProvider.download(url, filepath; verbose=verbose)
        end

        product_hashes = product_hashes_from_dir(d; verbose=verbose)
    end

    return product_hashes
end
