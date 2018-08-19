using BinaryProvider

function pull_latest(url, dir)
    # Get the repo that we've already cloned, or clone a new one
    repo = if !isdir(dir)
        @info("Cloning $(basename(url))")
        LibGit2.clone(url, dir)
    else
        @info("Updating $(basename(url))")
        LibGit2.GitRepo(dir)
    end

    # Fetch latest changes
    LibGit2.fetch(repo)
    
    # Reset ourselves onto the latest `master`
    master_oid = LibGit2.GitCommit(repo, "remotes/origin/master")
    LibGit2.reset!(repo, master_oid, LibGit2.Consts.RESET_HARD)
    return nothing
end

# live_laugh_love(;irony=false)
function clone_build_test(builder_url, package_url, package_deps)
    # First, check out the builder and start building it
    builder_dir = abspath(joinpath("builder_repos", basename(builder_url)))
    pull_latest(builder_url, builder_dir)

    # Build for the current platform
    name, version, product_hashes = try
        cd(builder_dir) do
            @info("Building $(basename(builder_url))")
            m = Module(:__anon__)
            Core.eval(m, quote
                ARGS = [$(triplet(platform_key()))]
                product_hashes = Base.include($m, joinpath($(builder_dir), "build_tarballs.jl"))

                # Write out a build.jl file that points to this tarball
                bin_path = joinpath($(builder_dir), "products")
                BinaryBuilder.print_buildjl($(builder_dir), name, version, products(Prefix(bin_path)), product_hashes, bin_path)

                # Return back these three pieces of information
                return name, version, product_hashes
            end)
        end
    catch e
        display(e)
        @warn("Building $(basename(builder_url)) failed.")
        return false
    end

    # Next, check out the package and its deps
    pkg_src_dirs = String[]
    for dep_url in package_deps
        dep_dir = abspath(joinpath("package_repos", basename(dep_url)))
        pull_latest(dep_url, dep_dir)
        push!(pkg_src_dirs, joinpath(dep_dir, "src"))
    end
    package_dir = abspath(joinpath("package_repos", basename(package_url)))
    pull_latest(package_url, package_dir)
    push!(pkg_src_dirs, joinpath(package_dir, "src"))
    pkg_env = merge(ENV, Dict("JULIA_LOAD_PATH" => join(pkg_src_dirs, ':')))

    # Copy over the new build.jl file and build it
    cp(joinpath(builder_dir, "products", "build_$(name).v$(version).jl"), joinpath(package_dir, "deps", "build.jl"); force=true)

    try
        @info("Building $(basename(package_url))")
        run(setenv(`$(Base.julia_cmd()) $(joinpath(package_dir, "deps", "build.jl"))`, pkg_env))
    catch e
       display(e)
        @warn("Building $(basename(package_url)) failed.")
        return false
    end

    # Finally, test that package!
    try
        @info("Testing $(basename(package_url))")
        cd(joinpath(package_dir, "test")) do
            run(setenv(`$(Base.julia_cmd()) runtests.jl`, pkg_env))
        end
    catch e
        display(e)
        @warn("Testing $(basename(package_url)) failed.")
        return false
    end
    return true
end



# Some test cases that ensure we can build and pass tests on a few different packages
test_cases = [
    ("https://github.com/staticfloat/OggBuilder", "https://github.com/staticfloat/Ogg.jl", ["https://github.com/JuliaIO/FileIO.jl"]),
    ("https://github.com/staticfloat/NettleBuilder", "https://github.com/staticfloat/Nettle.jl", []),
    # These disabled until they get updated with versioned outputs
    #("https://github.com/bicycle1885/ZlibBuilder", "https://github.com/bicycle1885/CodecZlib.jl", ["https://github.com/bicycle1885/TranscodingStreams.jl"]),
    #("https://github.com/JuliaWeb/MbedTLSBuilder", "https://github.com/JuliaWeb/MbedTLS.jl", []),
    # This segfaults for some reason.
    #("https://github.com/staticfloat/IpoptBuilder", "https://github.com/JuliaOpt/Ipopt.jl", ["https://github.com/JuliaOpt/MathProgBase.jl", "https://github.com/JuliaOpt/MathOptInterface.jl"]),
    # This awaiting the merging of https://github.com/davidanthoff/SnappyBuilder/pull/1
    #("https://github.com/davidanthoff/SnappyBuilder", "https://github.com/bicycle1885/Snappy.jl", []),
    # This awaiting https://github.com/dancasimiro/WAV.jl/pull/59
    #("https://github.com/staticfloat/FLACBuilder", "https://github.com/dmbates/FLAC.jl", ["https://github.com/staticfloat/Ogg.jl", "https://github.com/JuliaIO/FileIO.jl", "https://github.com/dancasimiro/WAV.jl"]),
]

mkpath("builder_repos")
mkpath("package_repos")

# Check everything out
@testset "Ecosystem tests" begin
    for (builder_url, package_url, package_deps) in test_cases
        @testset "$(basename(package_url))" begin
            @test clone_build_test(builder_url, package_url, package_deps)
        end
    end
end

