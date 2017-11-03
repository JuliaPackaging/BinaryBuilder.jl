export autobuild

"""
    autobuild(dir::AbstractString, src_name::AbstractString, platforms::Vector,
              sources::Vector, script, products)

Runs the boiler plate code to download, build, and package a source package
for multiple platforms.  `src_name`
"""
function autobuild(dir::AbstractString, src_name::AbstractString,
                   platforms::Vector, sources::Vector, script, products)
    # First, download the source(s), store in ./downloads/
    downloads_dir = joinpath(dir, "downloads")
    try mkpath(downloads_dir) end
    for idx in 1:length(sources)
        src_url, src_hash = sources[idx]
        if isfile(src_url)
            # Immediately abspath() a src_url so we don't lose track of
            # sources given to us with a relative path
            src_path = abspath(src_url)

            # Save it back for later use
            sources[idx] = (src_path, src_hash)

            # And if this is a locally-sourced tarball, just verify
            verify(src_path, src_hash; verbose=true)
        else
            # Otherwise, download and verify
            src_path = joinpath(downloads_dir, basename(src_url))
            download_verify(src_url, src_hash, src_path; verbose=true)
        end
    end

    # Our build products will go into ./products
    out_path = joinpath(dir, "products")
    rm(out_path; force=true, recursive=true)
    mkpath(out_path)

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
            prefix, ur = setup_workspace(build_path, src_paths, src_hashes, platform; verbose=true)

            prdcts = products(prefix)

            # Build the script
            steps = [`/bin/bash -c $script`]

            dep = Dependency(src_name, prdcts, steps, platform, prefix)
            build(ur, dep; verbose=true, autofix=true)

            # Once we're built up, go ahead and package this prefix out
            tarball_path, tarball_hash = package(prefix, joinpath(out_path, src_name); platform=platform, verbose=true)
            product_hashes[target] = (basename(tarball_path), tarball_hash)
        end

        # Finally, destroy the build_path
        rm(build_path; recursive=true)
    end

    # In the end, dump an informative message telling the user how to download/install these
    info("Hash/filename pairings:")
    for target in keys(product_hashes)
        filename, hash = product_hashes[target]
        println("    $(platform_key(target)) => (\"\$bin_prefix/$(filename)\", \"$(hash)\"),")
    end
end
