export autobuild, print_buildjl, product_hashes_from_github_release
import GitHub: gh_get_json, DEFAULT_API
import SHA: sha256


"""
    autobuild(dir::AbstractString, src_name::AbstractString, platforms::Vector,
              sources::Vector, script, products)

Runs the boiler plate code to download, build, and package a source package
for multiple platforms.  `src_name`
"""
function autobuild(dir::AbstractString, src_name::AbstractString,
                   platforms::Vector, sources::Vector, script, products;
                   dependencies::Vector = AbstractDependency[],
                   verbose::Bool = true)
    # If we're on Travis and we're not verbose, schedule a task to output a "." every few seconds
    if haskey(ENV, "TRAVIS") && !verbose
        run_travis_busytask = true
        travis_busytask = @async begin
            # Don't let Travis think we're asleep...
            info("Brewing a pot of coffee for Travis...")
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

    # Finally, print out our awesome build.jl
    info("Use this as your deps/build.jl:")
    print_buildjl(STDOUT, product_hashes)

    product_hashes
end

function print_buildjl(io::IO, product_hashes::Dict; products::Vector{Product} = Product[],
                       bin_path::AbstractString = "https://<path to hosted binaries>")
    print(io, """
    using BinaryProvider

    # Parse some basic command-line arguments
    const verbose = "--verbose" in ARGS
    const prefix = Prefix(get([a for a in ARGS if a != "--verbose"], 1, joinpath(@__DIR__, "usr")))
    """)

    # If we have been given products, print out the products we're given.  Otherwise, print out an example:
    if isempty(products)
        print(io, """
        products = Product[
            # Instantiate products here, e.g.:
            # LibraryProduct(prefix, "libfoo", :libfoo),
            # ExecutableProduct(prefix, "fooifier", :fooifier),
            # FileProduct(joinpath(libdir(prefix), "pkgconfig", "libfoo.pc"), :libfoo_pc),
        ]

        """)
    else
        print(io, "products = Product[\n")
        for prod in products
            print(io, "    $(repr(prod))\n")
        end
        print(io, "]\n\n")
    end

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

            # Write out a deps.jl file that will contain mappings for our products
            write_deps_file(joinpath(@__DIR__, "deps.jl"), products)
        else
            # If we don't have a BinaryProvider-compatible .tar.gz to download, complain.
            # Alternatively, you could attempt to install from a separate provider,
            # build from source or something more even more ambitious here.
            error("Your platform \$(Sys.MACHINE) is not supported by this package!")
        end
    end
    """)
end

function print_buildjl(build_dir::AbstractString, products::Vector{Product}, product_hashes::Dict, bin_path::AbstractString)
    mkpath(joinpath(build_dir, "products"))
    open(joinpath(build_dir, "products", "build.jl"), "w") do io
        print_buildjl(io, product_hashes; products=products, bin_path=bin_path)
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
    release = gh_get_json(DEFAULT_API, "/repos/$(repo_name)/releases/tags/$(tag_name)")

    # Try to extract the platform key from each, use that to find all tarballs
    function can_extract_platform(filename)
        try
            extract_platform_key(filename)
            return true
        end
        if verbose
            info("Ignoring file $(filename); can't extract its platform key")
        end
        return false
    end
    assets = [a for a in release["assets"] if can_extract_platform(a["name"])]

    # Download each tarball, hash it, and reconstruct product_hashes.
    product_hashes = Dict()
    mktempdir() do d
        for asset in assets
            filepath = joinpath(d, asset["name"])
            BinaryProvider.download(asset["url"], filepath; verbose=verbose)
            hash = open(filepath) do file
                return bytes2hex(sha256(file))
            end

            if verbose
                info("Calculated $hash for $(asset["name"])")
            end
            file_triplet = triplet(extract_platform_key(asset["name"]))
            product_hashes[file_triplet] = (asset["name"], hash)
        end
    end

    return product_hashes
end
