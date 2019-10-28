# Only update yggdrasil once
yggdrasil_updated = false
function get_yggdrasil()
    # TODO: Eventually, we want to use a Pkg cache to store Yggdrasil,
    # but since that doens't exist yet, we'll stick it into `deps`:
    yggdrasil_dir = abspath(joinpath(@__DIR__, "..", "..", "deps", "Yggdrasil"))

    if !isdir(yggdrasil_dir)
        @info("Cloning bare Yggdrasil into deps/Yggdrasil...")
        LibGit2.clone("https://github.com/JuliaPackaging/Yggdrasil.git", yggdrasil_dir; isbare=true)
    else
        if !yggdrasil_updated
            @info("Updating bare Yggdrasil clone in deps/Yggdrasil...")
            LibGit2.fetch(LibGit2.GitRepo(yggdrasil_dir))
        end
    end
    global yggdrasil_updated = true
    return yggdrasil_dir
end

"""
    yggdrasil_build_tarballs_path(name::String)

Return the relative path within an Yggdrasil clone where this project (given
its name) would be stored.  This is useful for things like generating the
`build_tarballs.jl` file and checking to see if it already exists, etc...

Note that we do not allow case-ambiguities within Yggdrasil, we check for this
using the utility function `case_insensitive_file_exists(path)`.
"""
function yggdrasil_build_tarballs_path(name)
    dir = uppercase(name[1])
    return "$(dir)/$(name)/build_tarballs.jl"
end

function case_insensitive_file_exists(path)
    # Start with an absolute path
    path = abspath(path)

    # Walk from top-to-bottom, checking all branches for the eventual leaf node
    spath = splitpath(path)
    branches = String[spath[1]]
    for node in spath[2:end]
        lnode = lowercase(node)
        
        new_branches = String[]
        for b in branches
            for bf in readdir(b)
                if lowercase(bf) == lnode
                    push!(new_branches, joinpath(b, bf))
                end
            end
        end

        branches = new_branches
        if isempty(branches)
            return false
        end
    end
    return !isempty(branches)
end