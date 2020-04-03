"""
    translate_symlinks(root::AbstractString; verbose::Bool=false)

Walks through the root directory given within `root`, finding all symlinks that
point to an absolute path within `root`, and rewriting them to be a relative
symlink instead, increasing relocatability.
"""
function translate_symlinks(root::AbstractString; verbose::Bool=false)
    for f in collect_files(root, islink)
        link_target = readlink(f)
        if isabspath(link_target) && startswith(link_target, "/workspace")
            new_link_target = relpath(link_target, replace(dirname(f), root => "/workspace/destdir"))
            if verbose
                @info("Translating $f to point to $(new_link_target)")
            end
            rm(f; force=true)
            symlink(new_link_target, f)
        end
    end
end

"""
    warn_deadlinks(root::AbstractString)

Walks through the given `root` directory, finding broken symlinks and warning
the user about them.  This is used to catch instances such as a build recipe
copying a symlink that points to a dependency; by doing so, it implicitly
breaks relocatability.
"""
function warn_deadlinks(root::AbstractString)
    for f in collect_files(root, islink; exclude_externalities=false)
        link_target = readlink(f)
        if !startswith(link_target, "/")
            # If the link is relative, prepend the dirname of `f` to
            # `link_target`, otherwise `isfile(link_target)` will always be
            # false, as the test isn't performed in dirname(f).  Why Not using
            # `isabspath`?  Because that command is platform-dependent, but we
            # always build in a Unix-like environment.
            link_target = joinpath(dirname(f), link_target)
        end
        if !ispath(link_target)
            @warn("Broken symlink: $(relpath(f, root))")
        end
    end
end
