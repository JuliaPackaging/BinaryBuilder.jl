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
            # For each build, create a temporary prefix we'll install into, then package up
            temp_prefix() do prefix
                for src_path in src_paths
                    # Unpack the source into our build directory
                    unpack(src_path, build_path; verbose=true)
                end

                prdcts = products(prefix)

                # Build the script
                steps = [`bash -c $script`]

                dep = Dependency(src_name, prdcts, steps, platform, prefix)
                build(dep; verbose=true, autofix=true)

                # Once we're built up, go ahead and package this prefix out
                tarball_path, tarball_hash = package(prefix, joinpath(out_path, src_name); platform=platform, verbose=true)
                product_hashes[target] = (basename(tarball_path), tarball_hash)
            end
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
