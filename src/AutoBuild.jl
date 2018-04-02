export build_tarballs, autobuild, print_buildjl, product_hashes_from_github_release
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256

"""
    build_tarballs(ARGS, src_name, sources, script, platforms, products,
                   dependencies)

This should be the top-level function called from a `build_tarballs.jl` file.
It takes in the information baked into a `build_tarballs.jl` file such as the
`sources` to download, the `products` to build, etc... and will automatically
download, build and package the tarballs, generating a `build.jl` file when
appropriate.  Note that `ARGS` should be the top-level Julia `ARGS` command-
line arguments object.
"""
function build_tarballs(ARGS, src_name, sources, script, platforms, products,
                        dependencies)
    # This sets whether we should build verbosely or not
    verbose = "--verbose" in ARGS
    ARGS = filter!(x -> x != "--verbose", ARGS)

    # This flag skips actually building and instead attempts to reconstruct a
    # build.jl from a GitHub release page.  Use this to automatically deploy a
    # build.jl file even when sharding targets across multiple CI builds.
    only_buildjl = "--only-buildjl" in ARGS
    ARGS = filter!(x -> x != "--only-buildjl", ARGS)

    # If we're only reconstructing a build.jl file, we _need_ this information
    # otherwise it's useless, so go ahead and error() out here.
    if only_buildjl && (!all(haskey.(ENV, ["TRAVIS_REPO_SLUG", "TRAVIS_TAG"])))
        msg = strip("""
        Must provide repository name and tag through Travis-style environment
        variables like TRAVIS_REPO_SLUG and TRAVIS_TAG!
        """)
        error(replace(msg, "\n" => " "))
    end

    # If the user passed in a platform (or a few, comma-separated) on the
    # command-line, use that instead of our default platforms
    should_override_platforms = length(ARGS) > 0
    if should_override_platforms
        platforms = platform_key.(split(ARGS[1], ","))
    end

    # If we're running on Travis and this is a tagged release, automatically
    # determine bin_path by building up a URL, otherwise use a default value.
    # The default value allows local builds to not error out
    bin_path = "https:://<path to hosted binaries>"
    if !isempty(get(ENV, "TRAVIS_TAG", ""))
        repo_name = ENV["TRAVIS_REPO_SLUG"]
        tag_name = ENV["TRAVIS_TAG"]
        bin_path = "https://github.com/$(repo_name)/releases/download/$(tag_name)"
    end

    product_hashes = if !only_buildjl
        # If the user didn't just ask for a `build.jl`, go ahead and actually build
        Compat.@info("Building for $(join(triplet.(platforms), ", "))")

        # Build the given platforms using the given sources
        autobuild(pwd(), src_name, platforms, sources, script,
                         products, dependencies; verbose=verbose)
    else
        msg = strip("""
        Reconstructing product hashes from GitHub Release $(repo_name)/$(tag_name)
        """)
        Compat.@info(msg)

        # Reconstruct product_hashes from github
        product_hashes_from_github_release(repo_name, tag_name; verbose=verbose)
    end

    # If we didn't override the default set of platforms OR we asked for only
    # a build.jl file, then write one out.  We don't write out when overriding
    # the default set of platforms because that is typically done either while
    # testing, or when we have sharded our tarball construction over multiple
    # invocations.
    if !should_override_platforms || only_buildjl
        dummy_prefix = Prefix(pwd())
        print_buildjl(pwd(), products(dummy_prefix), product_hashes, bin_path)

        if verbose
            Compat.@info("Writing out the following reconstructed build.jl:")
            print_buildjl(STDOUT, products(dummy_prefix), product_hashes, bin_path)
        end
    end
end


"""
    autobuild(dir::AbstractString, src_name::AbstractString, platforms::Vector,
              sources::Vector, script::AbstractString, products::Function,
              dependencies::Vector; verbose::Bool = true)

Runs the boiler plate code to download, build, and package a source package
for a list of platforms.  `src_name` represents the name of the source package
being built (and will set the name of the built tarballs), `platforms` is a
list of platforms to build for, `sources` is a list of tuples giving
`(url, hash)` of all sources to download and unpack before building begins,
`script` is a string representing a `bash` script to run to build the desired
products, which are listed as `Product` objects within the vector returned by
the `products` function. `dependencies` gives a list of dependencies that
provide `build.jl` files that should be installed before building begins to
allow this build process to depend on the results of another build process.
"""
function autobuild(dir::AbstractString, src_name::AbstractString,
                   platforms::Vector, sources::Vector,
                   script::AbstractString, products::Function,
                   dependencies::Vector = AbstractDependency[];
                   verbose::Bool = true)
    # If we're on Travis and we're not verbose, schedule a task to output a "." every few seconds
    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            Compat.@info("Brewing a pot of coffee for Travis...")
            while run_travis_busytask
                sleep(4)
                print(".")
            end
        end
    end

    # First, download the source(s), store in ./downloads/
    downloads_dir = joinpath(dir, "downloads")
    try mkpath(downloads_dir) end
    for idx in 1:length(sources)
        src_url, src_hash = sources[idx]
        if endswith(src_url, ".git")
            src_path = joinpath(downloads_dir, basename(src_url))
            if !isdir(src_path)
                repo = LibGit2.clone(src_url, src_path; isbare=true)
            else
                LibGit2.with(LibGit2.GitRepo(src_path)) do repo
                    LibGit2.fetch(repo)
                end
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
                src_path = joinpath(downloads_dir, basename(src_url))
                download_verify(src_url, src_hash, src_path; verbose=verbose)
            end
        end
        sources[idx] = (src_path => src_hash)
    end

    # Our build products will go into ./products
    out_path = joinpath(dir, "products")
    try mkpath(out_path) end
    product_hashes = Dict()

    for platform in platforms
        target = triplet(platform)

        # We build in a platform-specific directory
        build_path = joinpath(pwd(), "build", target)
        try mkpath(build_path) end

        cd(build_path) do
            src_paths, src_hashes = collect(zip(sources...))

            # Convert from tuples to arrays, if need be
            src_paths = collect(src_paths)
            src_hashes = collect(src_hashes)
            prefix, ur = setup_workspace(build_path, src_paths, src_hashes, dependencies, platform; verbose=verbose)

            # Don't keep the downloads directory around
            rm(joinpath(prefix, "downloads"); force=true, recursive=true)

            dep = Dependency(src_name, products(prefix), script, platform, prefix)
            if !build(ur, dep; verbose=verbose, autofix=true)
                error("Failed to build $(target)")
            end

            # Remove the files of any dependencies
            for dependency in dependencies
                dep_script = script_for_dep(dependency)
                m = Module(:__anon__)
                eval(m, quote
                    using BinaryProvider
                    platform_key() = $platform
                    macro write_deps_file(args...); end
                    function write_deps_file(args...); end
                    function install(url, hash;
                        prefix::Prefix = BinaryProvider.global_prefix,
                        kwargs...)
                        manifest_path = BinaryProvider.manifest_from_url(url; prefix=prefix)
                        BinaryProvider.uninstall(manifest_path; verbose=$verbose)
                    end
                    ARGS = [$(prefix.path)]
                    include_string($(dep_script))
                end)
            end

            # Once we're built up, go ahead and package this prefix out
            tarball_path, tarball_hash = package(prefix, joinpath(out_path, src_name); platform=platform, verbose=verbose, force=true)
            product_hashes[target] = (basename(tarball_path), tarball_hash)
        end

        # Finally, destroy the build_path
        rm(build_path; recursive=true)
    end

    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = false
        wait(travis_busytask)
        println()
    end

    # Return our product hashes
    return product_hashes
end

function print_buildjl(io::IO, products::Vector, product_hashes::Dict,
                       bin_path::AbstractString)
    print(io, """
    using BinaryProvider

    # Parse some basic command-line arguments
    const verbose = "--verbose" in ARGS
    const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
    """)

    # Print out products
    print(io, "products = [\n")
    for prod in products
        print(io, "    $(repr(prod)),\n")
    end
    print(io, "]\n\n")

    # Print binary locations/tarball hashes
    print(io, """
    # Download binaries from hosted location
    bin_prefix = "$bin_path"

    # Listing of files generated by BinaryBuilder:
    """)

    println(io, "download_info = Dict(")
    for platform in sort(collect(keys(product_hashes)))
        fname, hash = product_hashes[platform]
        pkey = platform_key(platform)
        println(io, "    $(pkey) => (\"\$bin_prefix/$(fname)\", \"$(hash)\"),")
    end
    println(io, ")\n")

    print(io, """
    # First, check to see if we're all satisfied
    if any(!satisfied(p; verbose=verbose) for p in products)
        if haskey(download_info, platform_key())
            # Download and install binaries
            url, tarball_hash = download_info[platform_key()]
            install(url, tarball_hash; prefix=prefix, force=true, verbose=verbose)
        else
            # If we don't have a BinaryProvider-compatible .tar.gz to download, complain.
            # Alternatively, you could attempt to install from a separate provider,
            # build from source or something more even more ambitious here.
            error("Your platform \$(triplet(platform_key())) is not supported by this package!")
        end
    end

    # Write out a deps.jl file that will contain mappings for our products
    write_deps_file(joinpath(@__DIR__, "deps.jl"), products)
    """)
end

function print_buildjl(build_dir::AbstractString, products::Vector,
                       product_hashes::Dict, bin_path::AbstractString)
    mkpath(joinpath(build_dir, "products"))
    open(joinpath(build_dir, "products", "build.jl"), "w") do io
        print_buildjl(io, products, product_hashes, bin_path)
    end
end

"""
If you have a sharded build on Github, it would be nice if we could get an auto-generated
`build.jl` just like if we build serially.  This function eases the pain by reconstructing
it from a releases page.
"""
function product_hashes_from_github_release(repo_name::AbstractString, tag_name::AbstractString;
                                            verbose::Bool = false)
    # Get list of files within this release
    release = gh_get_json(DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)", auth=github_auth)

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        # Short-circuit build.jl because that's quite often there.  :P
        if filename == "build.jl"
            return false
        end

        unknown_platform = typeof(extract_platform_key(filename)) <: UnknownPlatform
        if unknown_platform && verbose
            Compat.@info("Ignoring file $(filename); can't extract its platform key")
        end
        return !unknown_platform
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            # For each asset (tarball), download it
            filepath = joinpath(d, asset["name"])
            url = asset["browser_download_url"]
            BinaryProvider.download(url, filepath; verbose=verbose)

            # Hash it
            hash = open(filepath) do file
                return bytes2hex(sha256(file))
            end

            # Then fit it into our product_hashes
            file_triplet = triplet(extract_platform_key(asset["name"]))
            product_hashes[file_triplet] = (asset["name"], hash)

            if verbose
                Compat.@info("Calculated $hash for $(asset["name"])")
            end
        end
    end

    return product_hashes
end
