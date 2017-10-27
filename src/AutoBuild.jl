function autobuild(dir, src_name, platforms, sources, script, products)

    # First, download the source(s), store in ./downloads/
    downloads_dir = joinpath(dir, "downloads")
    try mkpath(downloads_dir) end
    src_paths = String[]
    for (src_hash, src_url) in sources
        src_path = joinpath(downloads_dir, basename(src_url))
        push!(src_paths, src_path)
        download_verify(src_url, src_hash, src_path; verbose=true)
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
            prefix, ur = setup_workspace(build_path, src_paths, platform; verbose=true)

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
