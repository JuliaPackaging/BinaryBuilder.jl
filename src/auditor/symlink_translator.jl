"""
    translate_symlinks(root::AbstractString; verbose::Bool=false)

Walks through the root directory given within `root`, finding all symlinks that
point to an absolute path within `root`, and rewriting them to be a relative
symlink instead, increasing relocatability.
"""
function translate_symlinks(root::AbstractString; verbose::Bool=false, io::IO = stdout)
    for f in collect_files(root, islink)
        link_target = readlink(f)
        if isabspath(link_target) && startswith(link_target, "/workspace")
            new_link_target = relpath(link_target, replace(dirname(f), root => "/workspace/destdir"))
            if verbose
                info(io, "Translating $f to point to $(new_link_target)")
            end
            rm(f; force=true)
            symlink(new_link_target, f)
        end
    end
end
